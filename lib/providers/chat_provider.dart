import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/chat_session.dart';
import '../models/download.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/image_service.dart';
import '../services/local_llm_service.dart';
import '../services/storage_service.dart';
import '../services/tool_orchestrator.dart';
import '../services/tool_service.dart';
import '../services/tools/tool_registry.dart';
import 'settings_provider.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider(
    this._storage,
    this._api,
    this._tools,
    this._images,
    this._localLlm,
    this._settings,
    this._downloads,
  ) {
    _restoreActiveSession();
  }

  final StorageService _storage;
  final ApiService _api;
  final ToolService _tools;
  final ImageService _images;
  final LocalLlmService _localLlm;
  final SettingsProvider _settings;
  final DownloadService _downloads;
  final _uuid = const Uuid();

  /// Owns the multi-round tool-calling loop. Stateless from the
  /// provider's perspective; one instance is enough for the whole
  /// app lifetime.
  final ToolOrchestrator _orchestrator = ToolOrchestrator();

  /// The currently active session (the conversation whose messages
  /// are visible in the chat list). Null when the user has just
  /// opened the app and no session is selected yet.
  ChatSession? _activeSession;

  /// Lightweight metadata list for the session manager UI. We
  /// refresh this in-place whenever the repo changes so the home
  /// page can render the session picker without a Hive round-trip.
  List<ChatSession> _sessionSummaries = const [];

  /// True while a request is in flight on the active session.
  bool _sending = false;
  bool _disposed = false;

  /// The id of the session the local-llm `ChatSession` instance is
  /// currently bound to. We re-seed the engine's KV cache only when
  /// the user switches to a different session; per-turn chat
  /// reuses the same engine session, which keeps llama.cpp's
  /// prompt-prefix reuse hot.
  String? _localSessionId;

  /// Pending `ask_user` tool calls. When the model invokes ask_user
  /// we drop a [Completer] here keyed by the tool-call id; the
  /// message bubble's inline options call [resolveAskUser] when the
  /// user picks, which completes the future and unblocks the
  /// streaming `await`.
  final Map<String, Completer<String>> _pendingAskUser = {};

  // -------- Public read API --------

  /// The currently visible messages. Empty when no session is
  /// active.
  List<ChatMessage> get messages {
    final s = _activeSession;
    if (s == null) return const [];
    return List.unmodifiable(s.messages);
  }

  /// Newest-first session summaries, for the session manager UI.
  List<ChatSession> get sessions => List.unmodifiable(_sessionSummaries);

  /// The id of the active session (or empty string if none).
  String get activeSessionId => _activeSession?.id ?? '';

  bool get sending => _sending;

  bool get hasActiveSession => _activeSession != null;

  // -------- Session lifecycle --------

  /// Pick the most recent session (or the one stored as "active"
  /// in SharedPreferences) on app start. Called from the
  /// constructor.
  void _restoreActiveSession() {
    refreshSessionList();
    final all = _storage.sessions.list();
    if (all.isEmpty) {
      // First launch / after migration: create a starter session
      // so the home page is never empty.
      _createBlankSessionInternal();
      return;
    }
    final savedId = _storage.activeSessionId;
    ChatSession? picked;
    if (savedId != null && savedId.isNotEmpty) {
      picked = all.firstWhere((s) => s.id == savedId, orElse: () => all.first);
    } else {
      picked = all.first;
    }
    _setActiveSession(picked);
  }

  /// Re-read the session list from the repository. Call after any
  /// operation that might have changed the metadata (create,
  /// delete, switch).
  void refreshSessionList() {
    _sessionSummaries = _storage.sessions.list();
  }

  /// Replace [messages] with a fresh empty session and select it.
  Future<void> createNewSession() async {
    final session = _createBlankSessionInternal();
    setLocalSessionId(null);
    await _storage.sessions.save(session);
    await _storage.setActiveSessionId(session.id);
    refreshSessionList();
    notifyListeners();
  }

  ChatSession _createBlankSessionInternal() {
    final now = DateTime.now();
    final session = ChatSession(
      id: _uuid.v4(),
      title: 'New chat',
      createdAt: now,
      updatedAt: now,
      messages: const [],
    );
    _setActiveSession(session);
    return session;
  }

  /// Switch to a different session. Persists the choice in
  /// SharedPreferences so the same conversation reopens on next
  /// launch.
  Future<void> selectSession(String id) async {
    if (id == _activeSession?.id) return;
    final s = _storage.sessions.get(id);
    if (s == null) return;
    _setActiveSession(s);
    // Force the local-llm engine to reset+seed on the next turn of
    // the new session; the existing ChatSession binding is stale.
    setLocalSessionId(null);
    await _storage.setActiveSessionId(id);
    notifyListeners();
  }

  void _setActiveSession(ChatSession s) {
    _activeSession = s;
  }

  /// Delete one session. If it was the active one, fall back to the
  /// most recent remaining session (or create a blank one if there
  /// are none left).
  Future<void> deleteSession(String id) async {
    await deleteSessions([id]);
  }

  /// Delete a batch of sessions. Active-session reassignment rules
  /// are the same as [deleteSession].
  Future<void> deleteSessions(Iterable<String> ids) async {
    final idSet = ids.toSet();
    if (idSet.isEmpty) return;
    final wasActive =
        _activeSession != null && idSet.contains(_activeSession!.id);
    await _storage.sessions.deleteMany(idSet);
    refreshSessionList();
    if (wasActive) {
      final remaining = _storage.sessions.list();
      if (remaining.isEmpty) {
        final blank = _createBlankSessionInternal();
        await _storage.sessions.save(blank);
        await _storage.setActiveSessionId(blank.id);
      } else {
        _setActiveSession(remaining.first);
        await _storage.setActiveSessionId(remaining.first.id);
      }
      setLocalSessionId(null);
    }
    refreshSessionList();
    notifyListeners();
  }

  /// Backwards-compatible: clear the current session's messages
  /// (used by the legacy "clear chat" button; kept so the home page
  /// doesn't need a refactor in this commit).
  Future<void> clearMessages() async {
    final s = _activeSession;
    if (s == null) {
      _createBlankSessionInternal();
      notifyListeners();
      return;
    }
    for (final c in _pendingAskUser.values) {
      if (!c.isCompleted) c.completeError(ToolException('chat cleared'));
    }
    _pendingAskUser.clear();
    final cleared = s.copyWith(messages: const [], updatedAt: DateTime.now());
    _setActiveSession(cleared);
    await _storage.sessions.save(cleared);
    notifyListeners();
  }

  /// Called by the message bubble's inline option chips when the
  /// user picks. Unblocks the streaming `await` on this tool call.
  void resolveAskUser(String toolId, String selection) {
    final completer = _pendingAskUser[toolId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(selection);
    }
  }

  /// Returns up to 3 system prompt parts: [baseSystem, rolePrompt, skillsPrompt].
  /// Empty strings are filtered out so the caller only gets non-empty parts.
  List<String> _buildSystemPrompts() {
    String? rolePrompt;
    final role = _settings.activeRole;
    if (role != null && role.systemPrompt.isNotEmpty) {
      rolePrompt = role.systemPrompt;
    }

    String? skillsPrompt;
    final skills = _settings.activeSkills;
    if (skills.isNotEmpty) {
      final sb = StringBuffer();
      sb.writeln('你可以参考以下技能:');
      for (final s in skills) {
        sb.writeln('## ${s.name}');
        if (s.description.isNotEmpty) sb.writeln(s.description);
        if (s.content.isNotEmpty) sb.writeln(s.content);
        sb.writeln();
      }
      skillsPrompt = sb.toString().trim();
    }

    String? baseSystem;
    if (_settings.toolsEnabled) {
      baseSystem =
          '你是一个有用、诚实的助手。\n'
          '\n'
          '## 核心规则\n'
          '1. 不知道或不确定的信息必须用工具获取,禁止编造。'
          '不要假装调用工具——必须真正发出 function_call。\n'
          '2. 同一轮可连续调用多个工具,全部结果返回后再综合回复。\n'
          '3. 工具出错时向用户说明原因并给出替代方案,不要直接结束。\n'
          '4. 回复简洁,不啰嗦。\n'
          '\n'
          '## 各工具使用要点(具体参数看 function schema)\n'
          '- memory(长期记忆):写入时给 tags,查询时用 keywords[] 多个相关词 OR 匹配。'
          '没线索时先 list。记忆由用户管理,你不必保证"绝不遗忘"。\n'
          '- location:获取当前位置。\n'
          '- fetch_web:默认不返回链接列表(节约 token)。要进入下一级只需把看到的'
          '链接文字传给 link_text,工具会返回 link_url,再用它继续 fetch。'
          'include_links=true 仅作最后手段。\n'
          '- ask_user:需要用户确认或选择时调用。\n'
          '- 其余工具按参数说明使用即可。';
    }

    return [
      if (baseSystem != null && baseSystem.isNotEmpty) baseSystem,
      if (rolePrompt != null && rolePrompt.isNotEmpty) rolePrompt,
      if (skillsPrompt != null && skillsPrompt.isNotEmpty) skillsPrompt,
    ];
  }

  List<Map<String, dynamic>> _buildToolsSchema() {
    final tools = _settings.activeTools;
    final list = <Map<String, dynamic>>[];
    for (final t in tools) {
      final tool = ToolRegistry.byId(t.id);
      if (tool == null || !tool.isSupportedOnCurrentPlatform) continue;
      final schema = tool.buildSchema();
      if (schema.isNotEmpty) list.add(schema);
    }
    return list;
  }

  // -------- Mutators (operate on the active session) --------

  /// Replace the active session's message list. Used after every
  /// UI mutating event (stream chunks, tool start/done, retry).
  void _replaceMessages(List<ChatMessage> messages) {
    final s = _activeSession;
    if (s == null) return;
    _setActiveSession(
      s.copyWith(
        messages: List<ChatMessage>.unmodifiable(messages),
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Append a fresh user + assistant placeholder pair to the
  /// active session. Returns the new assistant message id so the
  /// stream listener can find it.
  String _appendUserAndAssistantPlaceholders(
    String userContent,
    List<String> imagePaths,
  ) {
    final s = _activeSession;
    if (s == null) {
      // No session yet — create one and try again. This shouldn't
      // happen because `_restoreActiveSession` always leaves a
      // session in place, but we keep the guard for testability.
      final blank = _createBlankSessionInternal();
      _setActiveSession(blank);
      return _appendUserAndAssistantPlaceholders(userContent, imagePaths);
    }
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: userContent,
      imagePaths: List.unmodifiable(imagePaths),
    );
    final assistantId = _uuid.v4();
    final assistantMsg = ChatMessage(
      id: assistantId,
      role: MessageRole.assistant,
      content: '',
      streaming: true,
    );
    _replaceMessages([...s.messages, userMsg, assistantMsg]);

    // If this is the first user message of a fresh session,
    // derive a title for the session list.
    if (s.messages.isEmpty && userContent.isNotEmpty) {
      final titled = _activeSession!.copyWith(
        title: ChatSession.deriveTitle(userContent),
      );
      _setActiveSession(titled);
    }
    return assistantId;
  }

  Future<String> _onToolCall(
    BuildContext context,
    Map<String, dynamic> toolCall,
    String assistantId,
  ) async {
    final name = toolCall['name'] as String? ?? '';
    final args =
        (toolCall['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (name) {
      case 'fetch_web':
        final url = args['url'] as String? ?? '';
        if (url.isEmpty) {
          throw ToolException('url is required');
        }
        return await _tools.fetchWeb(
          url,
          linkText: args['link_text'] as String?,
          includeLinks: args['include_links'] as bool? ?? false,
        );
      case 'current_time':
        return await _tools.currentTime();
      case 'ask_user':
        final question = args['question'] as String? ?? '';
        final options = (args['options'] as List?)?.cast<String>() ?? const [];
        final multiSelect = args['multi_select'] as bool? ?? false;
        final toolId = toolCall['id'] as String? ?? '';
        if (question.isEmpty) {
          throw ToolException('question is required');
        }
        if (options.length < 2) {
          throw ToolException('at least 2 options are required');
        }
        // Stash the question/options on the tool call so the chat
        // bubble can render the inline option chips. The stream is
        // paused on the `await` below until the user picks.
        final s = _activeSession;
        if (s != null) {
          _replaceMessages([
            for (final m in s.messages)
              if (m.id == assistantId)
                m.copyWith(
                  toolCalls: [
                    for (final tc in m.toolCalls)
                      if (tc.id == toolId)
                        tc.copyWith(
                          question: question,
                          options: options,
                          multiSelect: multiSelect,
                        )
                      else
                        tc,
                  ],
                )
              else
                m,
          ]);
          notifyListeners();
        }
        final completer = Completer<String>();
        _pendingAskUser[toolId] = completer;
        try {
          return await completer.future;
        } finally {
          _pendingAskUser.remove(toolId);
        }
      case 'run_command':
        final command = args['command'] as String? ?? '';
        final cwd = args['cwd'] as String?;
        final timeout = (args['timeout_seconds'] as int?) ?? 30;
        if (command.trim().isEmpty) {
          throw ToolException('command is required');
        }
        return await _tools.runCommand(
          command: command,
          cwd: cwd,
          timeoutSeconds: timeout,
        );
      case 'get_environment':
        return await _tools.getEnvironment();
      case 'calendar':
        return await _tools.runCalendar(args);
      case 'reminders':
        return await _tools.runReminders(args);
      case 'notes':
        return await _tools.runNotes(args);
      case 'tasks':
        return await _tools.runTasks(args);
      case 'memory':
        return await _tools.runMemory(args);
      case 'location':
        return await _tools.runLocation(args);
      case 'download':
        return await _runDownload(context, toolCall, assistantId, args);
      default:
        throw ToolException('unknown tool: $name');
    }
  }

  /// Backs the `download` tool. Spawns a [DownloadItem] on the
  /// in-flight tool call, streams the URL to the app's temp
  /// directory, surfaces byte-level progress so the chat bubble's
  /// progress bar can repaint live, and returns a JSON envelope
  /// summarizing the result once the file is in temp storage. The
  /// user then taps "Save" in the bubble to pick a destination
  /// directory and copy the file out of temp.
  Future<String> _runDownload(
    BuildContext context,
    Map<String, dynamic> toolCall,
    String assistantId,
    Map<String, dynamic> args,
  ) async {
    final url = args['url'] as String? ?? '';
    if (url.isEmpty) {
      throw ToolException('url is required');
    }
    final filename = args['filename'] as String?;
    final toolId = toolCall['id'] as String? ?? '';
    if (toolId.isEmpty) {
      throw ToolException('tool call id is missing');
    }

    final downloadId = _downloads.newDownloadId();
    // Create a placeholder DownloadItem on the tool call so the
    // bubble can render the progress row from the very first
    // frame, even before any bytes arrive.
    final placeholder = DownloadItem(
      id: downloadId,
      url: url,
      filename: filename ?? 'download',
      status: DownloadStatus.pending,
    );
    _mutateToolCall(assistantId, toolId, (tc) {
      return tc.copyWith(downloads: [...tc.downloads, placeholder]);
    });

    var lastBytesReceived = 0;
    DownloadItem? last;
    try {
      await for (final item in _downloads.download(
        url: url,
        filename: filename,
        downloadId: downloadId,
      )) {
        last = item;
        // Skip pure duplicate snapshots — the model's card and the
        // bubble both only care about byte-count changes and
        // status transitions.
        final bytesChanged = item.bytesReceived != lastBytesReceived;
        final isTerminal =
            item.isCompleted ||
            item.isFailed ||
            item.isCancelled ||
            item.isSaved;
        if (!bytesChanged && !isTerminal) continue;
        lastBytesReceived = item.bytesReceived;
        _mutateToolCall(assistantId, toolId, (tc) {
          return tc.copyWith(
            downloads: [
              for (final d in tc.downloads)
                if (d.id == item.id) item else d,
            ],
          );
        });
        // notifyListeners is throttled at the streaming layer
        // (the chat-listening stream already drives it on every
        // toolStart / toolDone), so a manual call here is
        // mostly for the in-between progress frames. We still
        // emit it so the progress bar can repaint without
        // waiting for the next token.
        notifyListeners();
      }
    } catch (e) {
      // _downloads.download only re-throws on hard validation
      // errors (bad URL); per-download HTTP errors are already
      // surfaced as a `failed` snapshot via the stream. So this
      // branch is for the truly catastrophic case (path_provider
      // blew up, etc.).
      _mutateToolCall(assistantId, toolId, (tc) {
        return tc.copyWith(
          downloads: [
            for (final d in tc.downloads)
              if (d.id == downloadId)
                d.copyWith(status: DownloadStatus.failed, error: e.toString())
              else
                d,
          ],
        );
      });
      notifyListeners();
      rethrow;
    }

    final terminal = last;
    if (terminal == null) {
      throw ToolException('download stream closed without a final state');
    }
    if (terminal.isFailed) {
      throw ToolException(terminal.error ?? 'download failed');
    }
    if (terminal.isCancelled) {
      throw ToolException('download cancelled');
    }
    // The model only needs a small envelope — the file is on
    // disk, the user can see the card, the assistant's job is
    // done. The bubble handles the actual save flow.
    return jsonEncode({
      'action': 'download',
      'status': 'completed',
      'id': downloadId,
      'url': url,
      'filename': terminal.filename,
      'size_bytes': terminal.bytesReceived,
    });
  }

  /// In-place mutation of one [ToolCall] on the active session's
  /// assistant message. [transform] receives the current tool
  /// call and returns the replacement. Used by the download
  /// progress callback and the retry path. No-op when the
  /// session / message / tool call can't be found (which can
  /// happen mid-restart).
  void _mutateToolCall(
    String assistantId,
    String toolId,
    ToolCall Function(ToolCall tc) transform,
  ) {
    final s = _activeSession;
    if (s == null) return;
    _replaceMessages([
      for (final m in s.messages)
        if (m.id == assistantId)
          m.copyWith(
            toolCalls: [
              for (final tc in m.toolCalls)
                if (tc.id == toolId) transform(tc) else tc,
            ],
          )
        else
          m,
    ]);
  }

  /// Re-runs a single failed tool call from a finished assistant
  /// message. The tool is executed once, the in-place `ToolCall` is
  /// updated with the new result, and a synthetic user message is
  /// appended so the next user turn feeds the new result back to
  /// the model.
  Future<void> retryToolCall(
    BuildContext context,
    String assistantId,
    String toolId,
  ) async {
    if (_sending) return;
    final l10n = AppLocalizations.of(context);
    final s = _activeSession;
    if (s == null) return;
    final idx = s.messages.indexWhere((m) => m.id == assistantId);
    if (idx < 0) return;
    final assistant = s.messages[idx];
    final tcIdx = assistant.toolCalls.indexWhere((t) => t.id == toolId);
    if (tcIdx < 0) return;
    final tc = assistant.toolCalls[tcIdx];
    if (tc.status == ToolCallStatus.running) return;

    // Reset the tool call to running so the UI flips back to the
    // spinner, and clear any previous result/error.
    final updatedTool = tc.copyWith(
      status: ToolCallStatus.running,
      result: null,
      error: null,
      finishedAt: null,
    );
    _replaceMessages([
      for (final m in s.messages)
        if (m.id == assistantId)
          m.copyWith(
            toolCalls: [
              for (var i = 0; i < m.toolCalls.length; i++)
                if (i == tcIdx) updatedTool else m.toolCalls[i],
            ],
          )
        else
          m,
    ]);
    notifyListeners();

    // Re-execute the tool using the same dispatcher as the live
    // stream. We synthesize the input shape that the orchestrator
    // would have passed.
    Map<String, dynamic> argsMap;
    try {
      final decoded = jsonDecode(tc.arguments);
      argsMap = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{'raw': tc.arguments};
    } catch (_) {
      argsMap = <String, dynamic>{'raw': tc.arguments};
    }
    final syntheticCall = {'id': tc.id, 'name': tc.name, 'arguments': argsMap};
    String toolResult;
    bool success = true;
    String? toolError;
    try {
      toolResult = await _onToolCall(context, syntheticCall, assistantId);
    } catch (e) {
      toolResult = 'Error: $e';
      success = false;
      toolError = e.toString();
    }

    final finishedAt = DateTime.now();
    _replaceMessages([
      for (final m in s.messages)
        if (m.id == assistantId)
          m.copyWith(
            toolCalls: [
              for (var i = 0; i < m.toolCalls.length; i++)
                if (i == tcIdx)
                  updatedTool.copyWith(
                    status: success
                        ? ToolCallStatus.success
                        : ToolCallStatus.failed,
                    result: toolResult,
                    error: toolError,
                    finishedAt: finishedAt,
                  )
                else
                  m.toolCalls[i],
            ],
          )
        else
          m,
    ]);
    await _storage.sessions.save(_activeSession!);
    notifyListeners();

    if (success) {
      // Surface the new result as a user-facing system note so the
      // model picks it up on the next user turn. We use a real user
      // message (not an internal channel) so the retry semantics
      // are obvious in the chat history and the model treats it as
      // fresh context.
      final note = l10n.toolCallRetryNote(tc.name, toolResult);
      final cur = _activeSession!;
      _replaceMessages([
        ...cur.messages,
        ChatMessage(id: _uuid.v4(), role: MessageRole.user, content: note),
      ]);
      await _storage.sessions.save(_activeSession!);
      notifyListeners();
    }
  }

  Future<void> sendMessage(
    BuildContext context,
    String text, {
    List<String> imagePaths = const [],
  }) async {
    final l10n = AppLocalizations.of(context);
    final trimmed = text.trim();
    if ((trimmed.isEmpty && imagePaths.isEmpty) || _sending) return;
    final useLocal = _settings.useLocalModel;
    final provider = _settings.activeProvider;
    final localProvider = _settings.activeLocalProvider;
    if (useLocal) {
      if (localProvider == null) {
        final s = _activeSession;
        if (s != null) {
          _replaceMessages([
            ...s.messages,
            ChatMessage(
              id: _uuid.v4(),
              role: MessageRole.assistant,
              content: l10n.chatNoProvider,
            ),
          ]);
          await _storage.sessions.save(_activeSession!);
        }
        notifyListeners();
        return;
      }
    } else {
      if (provider == null) {
        final s = _activeSession;
        if (s != null) {
          _replaceMessages([
            ...s.messages,
            ChatMessage(
              id: _uuid.v4(),
              role: MessageRole.assistant,
              content: l10n.chatNoProvider,
            ),
          ]);
          await _storage.sessions.save(_activeSession!);
        }
        notifyListeners();
        return;
      }
      final model =
          provider.selectedModel ??
          (provider.models.isNotEmpty ? provider.models.first : null);
      if (model == null) {
        final s = _activeSession;
        if (s != null) {
          _replaceMessages([
            ...s.messages,
            ChatMessage(
              id: _uuid.v4(),
              role: MessageRole.assistant,
              content: l10n.chatNoModel,
            ),
          ]);
          await _storage.sessions.save(_activeSession!);
        }
        notifyListeners();
        return;
      }
    }

    final assistantId = _appendUserAndAssistantPlaceholders(
      trimmed,
      imagePaths,
    );
    _sending = true;
    await _storage.sessions.save(_activeSession!);
    refreshSessionList();
    notifyListeners();

    // Build request messages, converting any local image paths to
    // base64 data URLs just-in-time so we don't keep huge blobs in
    // memory. The user message's text (if any) is preserved; if the
    // user sent only images, the API will receive an image-only
    // content array which both OpenAI and Anthropic accept.
    final requestMessages = <ChatRequestMessage>[];
    for (final m in _activeSession!.messages) {
      if (m.id == assistantId) continue;
      if (m.role != MessageRole.user && m.role != MessageRole.assistant) {
        continue;
      }
      if (m.content.isEmpty && m.imagePaths.isEmpty) continue;
      final dataUrls = <String>[];
      for (final path in m.imagePaths) {
        if (!useLocal) {
          try {
            dataUrls.add(await _images.toBase64DataUrl(path));
          } catch (e) {
            // Skip this image silently rather than failing the whole
            // turn; the user can re-send if needed.
          }
        }
      }
      requestMessages.add(
        ChatRequestMessage(
          role: m.role,
          content: m.content,
          imageDataUrls: dataUrls,
          imagePaths: useLocal ? List.unmodifiable(m.imagePaths) : const [],
        ),
      );
    }

    final systemPrompts = _buildSystemPrompts();
    final tools = _buildToolsSchema();

    bool updated = false;
    StreamSubscription<StreamEvent>? sub;
    final controller = StreamController<void>();
    final completer = Completer<void>();

    final stream = useLocal
        ? _localLlm.streamChat(
            provider: localProvider!,
            systemPrompts: systemPrompts,
            messages: requestMessages,
            tools: tools,
            onToolCall: (tc) => _onToolCall(context, tc, assistantId),
            orchestrator: _orchestrator,
            boundSessionId: _activeSession?.id,
            onBoundSessionId: (id) => setLocalSessionId(id?.toString()),
          )
        : _api.streamChat(
            provider: provider!,
            model:
                provider.selectedModel ??
                (provider.models.isNotEmpty ? provider.models.first : ''),
            messages: requestMessages,
            systemPrompts: systemPrompts.isEmpty ? null : systemPrompts,
            tools: tools.isEmpty ? null : tools,
            onToolCall: (tc) => _onToolCall(context, tc, assistantId),
            orchestrator: _orchestrator,
          );

    sub = stream.listen(
      (event) {
        if (event.type == 'toolStart') {
          final s = _activeSession;
          if (s != null) {
            final toolId = event.toolId ?? '';
            _replaceMessages([
              for (final mm in s.messages)
                if (mm.id == assistantId)
                  mm.copyWith(
                    toolCalls: [
                      ...mm.toolCalls,
                      ToolCall(
                        id: toolId,
                        name: event.toolName ?? '',
                        arguments: event.toolArguments ?? '',
                        status: ToolCallStatus.running,
                      ),
                    ],
                  )
                else
                  mm,
            ]);
            controller.add(null);
          }
        } else if (event.type == 'toolDone') {
          final s = _activeSession;
          if (s != null) {
            final toolId = event.toolId ?? '';
            final now = DateTime.now();
            _replaceMessages([
              for (final mm in s.messages)
                if (mm.id == assistantId)
                  mm.copyWith(
                    toolCalls: [
                      for (final tc in mm.toolCalls)
                        if (tc.id == toolId)
                          tc.copyWith(
                            status: (event.toolSuccess ?? false)
                                ? ToolCallStatus.success
                                : ToolCallStatus.failed,
                            result: event.toolResult,
                            error: event.toolError,
                            finishedAt: now,
                          )
                        else
                          tc,
                    ],
                  )
                else
                  mm,
            ]);
            controller.add(null);
          }
        } else if (event.type == 'reasoning' && event.thinkingDelta != null) {
          final s = _activeSession;
          if (s != null) {
            _replaceMessages([
              for (final mm in s.messages)
                if (mm.id == assistantId)
                  mm.copyWith(thinking: mm.thinking + event.thinkingDelta!)
                else
                  mm,
            ]);
            if (!updated) {
              updated = true;
            }
            controller.add(null);
          }
        } else if (event.type == 'content' && event.contentDelta != null) {
          final s = _activeSession;
          if (s != null) {
            _replaceMessages([
              for (final mm in s.messages)
                if (mm.id == assistantId)
                  mm.copyWith(content: mm.content + event.contentDelta!)
                else
                  mm,
            ]);
            if (!updated) {
              updated = true;
            }
            controller.add(null);
          }
        } else if (event.type == 'error') {
          final s = _activeSession;
          if (s != null) {
            final errText = l10n.messageErrorPrefix(event.error ?? '');
            _replaceMessages([
              for (final mm in s.messages)
                if (mm.id == assistantId)
                  mm.copyWith(
                    content: mm.content.isEmpty
                        ? errText
                        : '${mm.content}\n\n$errText',
                  )
                else
                  mm,
            ]);
            controller.add(null);
          }
          if (!completer.isCompleted) completer.complete();
        } else if (event.type == 'done') {
          completer.complete();
        }
      },
      onError: (e) {
        final s = _activeSession;
        if (s != null) {
          final errText = l10n.messageErrorPrefix(e.toString());
          _replaceMessages([
            for (final mm in s.messages)
              if (mm.id == assistantId)
                mm.copyWith(
                  content: mm.content.isEmpty
                      ? errText
                      : '${mm.content}\n\n$errText',
                )
              else
                mm,
          ]);
          controller.add(null);
        }
        if (!completer.isCompleted) completer.complete();
      },
    );

    // Throttle notifyListeners to ~80ms during streaming and
    // debounce persistence to 300ms.
    Timer? persistTimer;
    Timer? notifyTimer;
    controller.stream.listen((_) {
      if (_disposed) return;
      if (notifyTimer == null) {
        notifyListeners();
        notifyTimer = Timer(const Duration(milliseconds: 80), () {
          notifyTimer = null;
        });
      }
      persistTimer?.cancel();
      persistTimer = Timer(const Duration(milliseconds: 300), () {
        if (_disposed) return;
        final cur = _activeSession;
        if (cur != null) {
          _storage.sessions.save(cur);
        }
      });
    });

    await completer.future;
    await sub.cancel();
    await controller.close();
    persistTimer?.cancel();
    final s = _activeSession;
    if (s != null) {
      _replaceMessages([
        for (final m in s.messages)
          if (m.id == assistantId) m.copyWith(streaming: false) else m,
      ]);
    }
    _sending = false;
    final cur = _activeSession;
    if (cur != null) {
      await _storage.sessions.save(cur);
    }
    refreshSessionList();
    if (!_disposed) notifyListeners();
  }

  /// Returns the id of the local ChatSession currently bound to the
  /// llama engine. Used by [LocalLlmService] to decide whether to
  /// reset+seed or just continue.
  String? get localSessionId => _localSessionId;

  /// Set the local-llm binding after the engine seeds its session.
  /// No-op if [sessionId] matches the current binding.
  void setLocalSessionId(String? sessionId) {
    _localSessionId = sessionId;
  }

  // -------- Download affordances (called from the message bubble) --------

  /// Cancels an in-flight download by id. Idempotent / safe to
  /// call on a finished download (no-op).
  void cancelDownload(String assistantId, String toolId, String downloadId) {
    _downloads.cancel(downloadId);
  }

  /// Copies a completed download's temp file to the user-picked
  /// [destDir] and updates the in-place [DownloadItem] with the
  /// final `savedPath`. The temp file is deleted as a side-effect
  /// (see [DownloadService.saveTo]). Throws [ToolException] if
  /// the temp file is gone (e.g. the app was restarted between
  /// download and save).
  Future<void> saveDownload({
    required String assistantId,
    required String toolId,
    required String downloadId,
    required String destDir,
  }) async {
    final s = _activeSession;
    if (s == null) return;
    final assistant = s.messages.firstWhere(
      (m) => m.id == assistantId,
      orElse: () =>
          ChatMessage(id: '', role: MessageRole.assistant, content: ''),
    );
    if (assistant.id.isEmpty) return;
    final tc = assistant.toolCalls.firstWhere(
      (t) => t.id == toolId,
      orElse: () => ToolCall(id: '', name: '', arguments: ''),
    );
    if (tc.id.isEmpty) return;
    final item = tc.downloads.firstWhere(
      (d) => d.id == downloadId,
      orElse: () => DownloadItem(
        id: '',
        url: '',
        filename: '',
        status: DownloadStatus.failed,
      ),
    );
    if (item.id.isEmpty) return;
    final savedPath = await _downloads.saveTo(item: item, destDir: destDir);
    _mutateToolCall(assistantId, toolId, (tc) {
      return tc.copyWith(
        downloads: [
          for (final d in tc.downloads)
            if (d.id == downloadId)
              d.copyWith(
                status: DownloadStatus.saved,
                localPath: null,
                savedPath: savedPath,
              )
            else
              d,
        ],
      );
    });
    notifyListeners();
  }

  /// Removes the temp file behind a download (e.g. when the
  /// user dismisses a completed-but-not-saved card). Idempotent.
  Future<void> discardDownload({
    required String assistantId,
    required String toolId,
    required String downloadId,
  }) async {
    final s = _activeSession;
    if (s == null) return;
    final assistant = s.messages.firstWhere(
      (m) => m.id == assistantId,
      orElse: () =>
          ChatMessage(id: '', role: MessageRole.assistant, content: ''),
    );
    if (assistant.id.isEmpty) return;
    final tc = assistant.toolCalls.firstWhere(
      (t) => t.id == toolId,
      orElse: () => ToolCall(id: '', name: '', arguments: ''),
    );
    if (tc.id.isEmpty) return;
    final item = tc.downloads.firstWhere(
      (d) => d.id == downloadId,
      orElse: () => DownloadItem(
        id: '',
        url: '',
        filename: '',
        status: DownloadStatus.failed,
      ),
    );
    if (item.id.isEmpty) return;
    await _downloads.cleanup(item);
    // No state change needed on the tool call — the temp file
    // was the only thing we owned. The UI may still want to
    // re-render to show the file as gone (e.g. on app restart,
    // `localPath` is set but the file no longer exists).
    notifyListeners();
  }

  @override
  void dispose() {
    for (final c in _pendingAskUser.values) {
      if (!c.isCompleted) {
        c.completeError(ToolException('disposed before user responded'));
      }
    }
    _pendingAskUser.clear();
    _disposed = true;
    super.dispose();
  }
}
