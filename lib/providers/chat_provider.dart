import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/chat_session.dart';
import '../models/download.dart';
import '../models/file_attachment.dart';
import '../models/mcp_provider.dart';
import '../models/message.dart';
import '../models/skill.dart';
import '../models/timer_task.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/file_attachment_service.dart';
import '../services/image_service.dart';
import '../services/local_llm_service.dart';
import '../services/storage_service.dart';
import '../services/timer_service.dart';
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
    this._fileAttachments,
  ) {
    _restoreActiveSession();
    // Wire the timer queue: when a task fires, the service calls
    // back here so we can append a synthetic user message to the
    // active session and trigger a new chat turn. The model then
    // sees the reminder and (typically) calls the `notification`
    // tool to surface a real notification.
    _tools.timers.onTimerFired = _onTimerFired;
  }

  final StorageService _storage;
  final ApiService _api;
  final ToolService _tools;
  final ImageService _images;
  final LocalLlmService _localLlm;
  final SettingsProvider _settings;
  final DownloadService _downloads;
  final FileAttachmentService _fileAttachments;
  final _uuid = const Uuid();

  /// Owns the multi-round tool-calling loop. Stateless from the
  /// provider's perspective; one instance is enough for the whole
  /// app lifetime.
  final ToolOrchestrator _orchestrator = ToolOrchestrator();

  /// Tracks the active stream subscription so [stopGeneration] can
  /// cancel it immediately.
  StreamSubscription<StreamEvent>? _streamSub;

  /// Most recent `BuildContext` from a [sendMessage] call. The
  /// timer-driven flow needs *some* `BuildContext` to look up
  /// l10n strings + drive tool-call overlays; we cache the
  /// overlay navigator's context here on every user-initiated
  /// turn. Stays valid as long as the home page is mounted.
  BuildContext? _cachedContext;

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

  /// Maps an assistant message id → (transport tool-call id →
  /// synthesized UI tool-call id). Populated in the `toolStart`
  /// branch when the transport id is non-empty but collides with
  /// an existing bubble id — in that case the UI bubble gets a
  /// fresh uuid, and the matching `toolDone` event (which still
  /// carries the original transport id) looks the synthesized id
  /// up here. Entries are removed as soon as the corresponding
  /// `toolDone` arrives, so the map stays small.
  final Map<String, Map<String, String>> _transportToUiToolCallId = {};

  /// Pure helper that decides what id to use for a new
  /// `ToolCall` bubble in [MessageBubble]. Three failure modes
  /// to defend against (see the `toolStart` branch of
  /// `sendMessage` for the full rationale):
  ///   1. `incomingId` is `null`/`''` → synthesize.
  ///   2. `incomingId` collides with an existing bubble on the
  ///      same message (Hermes-style models emit `call_0` for
  ///      every tool call) → synthesize.
  ///   3. `incomingId` is unique → use as-is.
  /// Extracted as a `@visibleForTesting` static so the resolution
  /// rules can be unit-tested without standing up the full
  /// provider / stream pipeline.
  @visibleForTesting
  static String resolveToolCallBubbleId({
    required String incomingId,
    required List<ToolCall> existingToolCalls,
    Uuid? uuid,
  }) {
    final collision =
        incomingId.isNotEmpty &&
        existingToolCalls.any((tc) => tc.id == incomingId);
    if (incomingId.isEmpty || collision) {
      final u = uuid ?? const Uuid();
      return 'local-${u.v4()}';
    }
    return incomingId;
  }

  // -------- Public read API --------

  /// The currently visible messages. Empty when no session is
  /// active. Includes hidden messages (the model needs to see
  /// them in the request list); use [visibleMessages] for UI
  /// rendering.
  List<ChatMessage> get messages {
    final s = _activeSession;
    if (s == null) return const [];
    return List.unmodifiable(s.messages);
  }

  /// Subset of [messages] with `hidden == true` filtered out.
  /// The chat UI uses this so synthetic "system" messages
  /// (currently the timer-fire reminder) don't render as user
  /// bubbles, even though they still count toward the model's
  /// request list. Returns the same empty-when-no-session
  /// behaviour as [messages].
  List<ChatMessage> get visibleMessages {
    return List.unmodifiable(messages.where((m) => !m.hidden));
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

  /// Returns the active system prompt parts.
  List<String> _buildSystemPrompts() {
    final thinkingPrompt = _settings.thinkingModeEnabled
        ? '当前已开启思考模式。请在回答前进行更充分的分析与推理，再给出准确、清晰的结论。'
        : '';
    String? rolePrompt;
    final role = _settings.activeRole;
    if (role != null && role.systemPrompt.isNotEmpty) {
      rolePrompt = role.systemPrompt;
    }

    String? skillsPrompt;
    final skills = _settings.activeSkills;
    if (skills.isNotEmpty) {
      final sb = StringBuffer();
      sb.writeln('可用技能(仅名称+简介,完整内容需用工具加载):');
      for (final s in skills) {
        sb.writeln(
          '- ${s.name}${s.description.isNotEmpty ? ': ${s.description}' : ''}',
        );
      }
      sb.writeln();
      sb.writeln('需要完整技能内容时,调用 load_skill 工具:');
      sb.writeln('load_skill(skill_name: "技能名称")  # 返回完整内容');
      skillsPrompt = sb.toString().trim();
    }

    String? baseSystem;
    if (_settings.toolsEnabled) {
      final mcpServers = _settings.mcpProviders
          .where((m) => m.enabled)
          .toList();
      final mcpHint = mcpServers.isNotEmpty
          ? '\n'
                '- MCP 工具(名称以 mcp__ 开头):这些是由外部 MCP 服务器动态提供的工具。'
                '每个工具的参数 schema 已经准确列出,按参数说明使用即可。'
                '当前已启用 ${mcpServers.length} 个 MCP 服务器。'
          : '';
      final workingDirectory = _settings.modelWorkingDirectory;
      final workingDirectoryHint = workingDirectory == null
          ? ''
          : '\n- 模型默认工作目录: $workingDirectory。file 和 run_command 的相对路径都基于此目录。';
      baseSystem =
          '你是一个有用、诚实的助手。\n'
          '\n'
          '## 核心规则\n'
          '1. 不知道就必须用工具查,禁止瞎编。必须真的发出 function_call,别装样子。\n'
          '2. 同一轮可以连续调多个工具,等全部结果回来再统一回复。\n'
          '3. 工具报错了就跟用户说明原因,给个替代方案,别直接完事。\n'
          '4. 回复简洁,别啰嗦。\n'
          '\n'
          '## 工具使用提醒(具体参数看 function schema)\n'
          '- fetch_web(抓网页):填 link_text 只返回链接 URL(不返回页面内容),'
          '必须再调一次 fetch_web 抓那个页面。一直深入直到找到答案。别只看首页。\n'
          '- memory(记忆):写入时带 tags;查询用 keywords[] 给多个相关词。'
          '没头绪就先 list。\n'
          '- location(位置):获取当前位置,别主动问用户。\n'
          '- ask_user(问用户):需要用户选择或确认时用。\n'
          '- file(文件):读/写/删/改名/列目录/查属性。优先使用相对路径。\n'
          '- timer(计时):用户说"X 分钟后提醒我 Y"就用这个。'
          'create 时给 delay_seconds(或 fire_at_iso)、label 必填,'
          'prompt 写提醒正文,action_hint 写"调用 notification 通知用户…"这种建议。'
          '**只在程序运行时有效,App 被杀就不响了**,长时段务必先告知用户。\n'
          '- notification(通知):给用户推一条本地通知(手机系统通知 / 电脑右下角弹窗)。'
          '计时器到点时,如果用户正看着聊天,就由你来调它把提醒正式发出去。\n'
          '- google_sheet(谷歌表格):操作用户在设置里配置的 Google Sheet。'
          'action=list_tabs 先拿表名,read/update/append/clear 用 A1 表示法(range),'
          'create_tab/delete_tab 增删整张表,format 改文字/格子属性。'
          '插入数据给二维数组 values,字符串以 `=` 开头会被当公式。\n'
          '- 其他工具按参数说明用就行。$workingDirectoryHint$mcpHint';
    }

    return [
      if (baseSystem != null && baseSystem.isNotEmpty) baseSystem,
      if (thinkingPrompt.isNotEmpty) thinkingPrompt,
      if (rolePrompt != null && rolePrompt.isNotEmpty) rolePrompt,
      if (skillsPrompt != null && skillsPrompt.isNotEmpty) skillsPrompt,
    ];
  }

  Future<List<Map<String, dynamic>>> _buildToolsSchema() async {
    final tools = _settings.activeTools;
    final list = <Map<String, dynamic>>[];
    for (final t in tools) {
      final tool = ToolRegistry.byId(t.id);
      if (tool == null || !tool.isSupportedOnCurrentPlatform) continue;

      // Skip the old call_mcp tool — MCP tools are now exposed via
      // individual dynamically-generated schemas below.
      if (tool.id == 'call_mcp') continue;

      final schema = tool.buildSchema();
      if (schema.isNotEmpty) list.add(schema);
    }
    // auto-include load_skill when there are active skills (skip if
    // already present to avoid duplicate function names).
    if (_settings.activeSkills.isNotEmpty &&
        !list.any((s) => s['function']?['name'] == 'load_skill')) {
      final ls = ToolRegistry.byId('load_skill');
      if (ls != null && ls.isSupportedOnCurrentPlatform) {
        final schema = ls.buildSchema();
        if (schema.isNotEmpty) list.add(schema);
      }
    }
    // Dynamically add MCP tools from enabled servers. Each MCP tool
    // becomes an individual function schema so the model sees the
    // exact tool name, description, and parameter schema.
    final mcpServers = _settings.mcpProviders.where((m) => m.enabled).toList();
    if (mcpServers.isNotEmpty) {
      for (final server in mcpServers) {
        try {
          final mcpTools = await _tools.mcp.getServerTools(server);
          for (final mt in mcpTools) {
            final schemaName = 'mcp__${server.name}__${mt.name}';
            list.add({
              'type': 'function',
              'function': {
                'name': schemaName,
                'description': mt.description,
                'parameters': mt.inputSchema.isNotEmpty
                    ? mt.inputSchema
                    : {
                        'type': 'object',
                        'properties': <String, dynamic>{},
                        'additionalProperties': true,
                      },
              },
            });
          }
        } catch (_) {
          // Skip servers that fail to respond — the model will still
          // see other available tools.
        }
      }
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
    List<ChatFileAttachment> fileAttachments,
  ) {
    final s = _activeSession;
    if (s == null) {
      // No session yet — create one and try again. This shouldn't
      // happen because `_restoreActiveSession` always leaves a
      // session in place, but we keep the guard for testability.
      final blank = _createBlankSessionInternal();
      _setActiveSession(blank);
      return _appendUserAndAssistantPlaceholders(
        userContent,
        imagePaths,
        fileAttachments,
      );
    }
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: userContent,
      imagePaths: List.unmodifiable(imagePaths),
      fileAttachments: List.unmodifiable(fileAttachments),
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
    if (s.messages.isEmpty &&
        (userContent.isNotEmpty || fileAttachments.isNotEmpty)) {
      final titleSource = userContent.isNotEmpty
          ? userContent
          : fileAttachments.first.name;
      final titled = _activeSession!.copyWith(
        title: ChatSession.deriveTitle(titleSource),
      );
      _setActiveSession(titled);
    }
    return assistantId;
  }

  /// Appends a fresh empty assistant placeholder and returns its
  /// id. Used by the timer-driven flow which has *already*
  /// appended the user message and just needs an assistant
  /// placeholder to stream the model's response into.
  String _appendAssistantPlaceholder() {
    final s = _activeSession;
    if (s == null) {
      // No session — same recovery as _appendUserAndAssistantPlaceholders.
      final blank = _createBlankSessionInternal();
      _setActiveSession(blank);
      return _appendAssistantPlaceholder();
    }
    final assistantId = _uuid.v4();
    final assistantMsg = ChatMessage(
      id: assistantId,
      role: MessageRole.assistant,
      content: '',
      streaming: true,
    );
    _replaceMessages([...s.messages, assistantMsg]);
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

    // Special cases that need ChatProvider state (ask_user, download,
    // load_skill) are handled directly. Everything else delegates to
    // the tool's own execute method via the registry.
    switch (name) {
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
      case 'download':
        return await _runDownload(context, toolCall, assistantId, args);
      case 'load_skill':
        return await _loadSkill(args);
      default:
        if (name.startsWith('mcp__')) {
          return await _onMcpToolCall(name, args);
        }
        {
          final tool = ToolRegistry.byId(name);
          if (tool == null || !tool.isSupportedOnCurrentPlatform) {
            throw ToolException('unknown or unavailable tool: $name');
          }
          return await tool.execute(args, _tools);
        }
    }
  }

  Future<String> _loadSkill(Map<String, dynamic> args) async {
    final name = (args['skill_name'] as String? ?? '').trim();
    if (name.isEmpty) {
      throw ToolException('请指定 skill_name');
    }
    final skills = _settings.activeSkills;
    // exact match first
    Skill? match;
    for (final s in skills) {
      if (s.name == name) {
        match = s;
        break;
      }
    }
    // fallback: case-insensitive
    if (match == null) {
      final lower = name.toLowerCase();
      for (final s in skills) {
        if (s.name.toLowerCase() == lower) {
          match = s;
          break;
        }
      }
    }
    if (match == null) {
      final names = skills.map((s) => '"${s.name}"').join(', ');
      throw ToolException('未找到技能"$name"。可用技能: $names');
    }
    final sb = StringBuffer();
    sb.writeln('## ${match.name}');
    if (match.description.isNotEmpty) sb.writeln(match.description);
    if (match.content.isNotEmpty) sb.writeln(match.content);
    return sb.toString().trim();
  }

  Future<String> _onMcpToolCall(
    String fullName,
    Map<String, dynamic> args,
  ) async {
    // fullName has the format: mcp__SERVER_NAME__TOOL_NAME
    final parts = fullName.split('__');
    if (parts.length < 3) {
      throw ToolException('invalid MCP tool name: $fullName');
    }
    // Skip the first empty element from "mcp"
    final serverName = parts[1];
    final toolName = parts.sublist(2).join('__');

    final server = _settings.mcpProviders.cast<McpProvider?>().firstWhere(
      (s) => s!.name == serverName && s.enabled,
      orElse: () => null,
    );
    if (server == null) {
      throw ToolException('MCP 服务器 "$serverName" 不可用(未找到或未启用)。');
    }

    return await _tools.mcp.callTool(
      server: server,
      toolName: toolName,
      arguments: args,
    );
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

  /// Callback bound to [TimerService.onTimerFired] (see the
  /// constructor). The timer has already:
  ///   1. transitioned the task to `fired` in the queue;
  ///   2. surfaced an OS-level notification / desktop toast so
  ///      the user is notified even before the AI responds.
  /// Our job is to feed the reminder back to the model so it can
  /// (typically) call the `notification` tool itself.
  ///
  /// Strategy: append a synthetic user message to the active
  /// session with a short, machine-readable reminder, then
  /// trigger a new chat turn via [continueWithLastUserMessage].
  /// If a turn is already in flight we defer the kick-off until
  /// it finishes — we don't interleave timer-driven and
  /// user-driven turns.
  void _onTimerFired(TimerTask task) {
    if (_disposed) return;
    final s = _activeSession;
    if (s == null) return;
    final text = _formatTimerFiredMessage(task);
    // The synthetic user message is part of the conversation —
    // the model must see it so it can react — but we don't want
    // it to render as a user bubble in the chat. `hidden: true`
    // is consumed by `MessageBubble.build` and dropped from the
    // ListView. The model still gets the message in the request
    // list because `_runAssistantTurn` iterates every message in
    // the session, hidden or not.
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: text,
      hidden: true,
    );
    _replaceMessages([...s.messages, userMsg]);
    unawaited(_storage.sessions.save(_activeSession!));
    notifyListeners();
    if (_sending) return;
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (_disposed || _sending) return;
      // Reuse the last user-send context; if we never had one
      // (e.g. cold start into a timer fire — shouldn't happen
      // because timers are scheduled by the AI) just bail.
      // ignore: use_build_context_synchronously
      final ctx = _cachedContext;
      if (ctx == null) return;
      // ignore: use_build_context_synchronously
      unawaited(continueWithLastUserMessage(ctx));
    });
  }

  String _formatTimerFiredMessage(TimerTask task) {
    final prompt = task.prompt.trim();
    final hint = task.actionHint?.trim() ?? '';
    final lines = <String>[
      '[系统计时触发] ${task.label}',
      if (prompt.isNotEmpty) '原提示:$prompt',
      if (hint.isNotEmpty) '建议操作:$hint' else '建议操作:调用 notification 工具通知用户。',
    ];
    return lines.join('\n');
  }

  Future<void> sendMessage(
    BuildContext context,
    String text, {
    List<String> imagePaths = const [],
    List<ChatFileAttachment> fileAttachments = const [],
  }) async {
    final l10n = AppLocalizations.of(context);
    final trimmed = text.trim();
    if ((trimmed.isEmpty && imagePaths.isEmpty && fileAttachments.isEmpty) ||
        _sending) {
      return;
    }
    _cachedContext = context;
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
      fileAttachments,
    );
    _sending = true;
    await _storage.sessions.save(_activeSession!);
    refreshSessionList();
    notifyListeners();
    // ignore: use_build_context_synchronously
    await _runAssistantTurn(context, assistantId);
  }

  /// Timer-driven entry point. The caller (TimerService) has
  /// already appended a synthetic user message to the active
  /// session. We append a fresh assistant placeholder, then run
  /// the same streaming loop [sendMessage] uses. No-op if a turn
  /// is already in flight (the timer callback will defer).
  Future<void> continueWithLastUserMessage(BuildContext context) async {
    if (_sending || _disposed) return;
    if (_activeSession == null) return;
    if (!_hasUsableProvider()) return;
    _cachedContext = context;
    final assistantId = _appendAssistantPlaceholder();
    _sending = true;
    refreshSessionList();
    notifyListeners();
    await _runAssistantTurn(context, assistantId);
  }

  /// Validates the user has selected a provider + model. Returns
  /// true when the streaming path can proceed. Used by both
  /// [sendMessage] and [continueWithLastUserMessage] to gate
  /// the turn before we burn any tokens.
  bool _hasUsableProvider() {
    if (_settings.useLocalModel) {
      return _settings.activeLocalProvider != null;
    }
    final p = _settings.activeProvider;
    if (p == null) return false;
    return p.selectedModel != null || p.models.isNotEmpty;
  }

  /// Shared streaming turn runner. Validates the provider / model,
  /// builds the request list, kicks off the streamChat call, and
  /// drives the listener that updates the in-place assistant
  /// message with reasoning / content / tool-call deltas. Used by
  /// both the user-initiated path ([sendMessage]) and the
  /// timer-driven path ([continueWithLastUserMessage]).
  Future<void> _runAssistantTurn(
    BuildContext context,
    String assistantId,
  ) async {
    final l10n = AppLocalizations.of(context);
    final useLocal = _settings.useLocalModel;
    final provider = _settings.activeProvider;
    final localProvider = _settings.activeLocalProvider;

    // Build request messages, converting any local image paths to
    // base64 data URLs just-in-time so we don't keep huge blobs in
    // memory. The user message's text (if any) is preserved; if the
    // user sent only images, the API will receive an image-only
    // content array which both OpenAI and Anthropic accept.
    final requestMessages = <ChatRequestMessage>[];
    final cur = _activeSession;
    if (cur == null) {
      _sending = false;
      if (!_disposed) notifyListeners();
      return;
    }
    for (final m in cur.messages) {
      if (m.id == assistantId) continue;
      if (m.role != MessageRole.user && m.role != MessageRole.assistant) {
        continue;
      }
      if (m.content.isEmpty &&
          m.imagePaths.isEmpty &&
          m.fileAttachments.isEmpty) {
        continue;
      }
      final dataUrls = <String>[];
      final preparedFiles = <PreparedFileAttachment>[];
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
      for (final attachment in m.fileAttachments) {
        try {
          preparedFiles.add(
            await _fileAttachments.prepare(
              attachment,
              includeBinaryData: !useLocal,
            ),
          );
        } catch (e) {
          preparedFiles.add(
            PreparedFileAttachment(
              name: attachment.name,
              path: attachment.path,
              size: attachment.size,
              mimeType: attachment.mimeType,
              textContent: '[Unable to read attached file: $e]',
            ),
          );
        }
      }
      requestMessages.add(
        ChatRequestMessage(
          role: m.role,
          content: m.content,
          imageDataUrls: dataUrls,
          imagePaths: useLocal ? List.unmodifiable(m.imagePaths) : const [],
          fileAttachments: List.unmodifiable(preparedFiles),
        ),
      );
    }

    final systemPrompts = _buildSystemPrompts();
    final tools = await _buildToolsSchema();

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
            enableThinking: _settings.thinkingModeEnabled,
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
            enableThinking: _settings.thinkingModeEnabled,
            onToolCall: (tc) => _onToolCall(context, tc, assistantId),
            orchestrator: _orchestrator,
          );

    _streamSub = sub;
    sub = stream.listen(
      (event) {
        if (event.type == 'toolStart') {
          final s = _activeSession;
          if (s != null) {
            // The id hygiene here is load-bearing. Three failure
            // modes we have to defend against:
            //   1. The transport (e.g. llamadart + Hermes) hands
            //      us `id: null` or `''`. Two siblings in the
            //      same turn would share the empty id and the
            //      Column in `MessageBubble` would throw
            //      "Duplicate keys found".
            //   2. The transport hands us a NON-empty id that
            //      *collides* with one already on this message
            //      — Hermes-style models emit `{"id": "call_0",
            //      ...}` for every tool call, so a 3-tool-call
            //      turn arrives as three `call_0`s.
            //   3. The transport hands us a non-empty id that
            //      collides *across* turns (the per-turn
            //      `call_$index` counter resets). That doesn't
            //      break the Column in a single message, but it
            //      would make `toolDone` for a later turn
            //      re-update an older message's ToolCall.
            // We always mint a fresh, unique id for the UI
            // bubble and record the mapping back to the
            // transport id so the matching `toolDone` event
            // (which still carries the transport id) can find
            // the right bubble.
            final incoming = event.toolId ?? '';
            final assistant = s.messages.firstWhere(
              (m) => m.id == assistantId,
              orElse: () => s.messages.first,
            );
            final toolId = resolveToolCallBubbleId(
              incomingId: incoming,
              existingToolCalls: assistant.toolCalls,
            );
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
            // Record the transport→UI id mapping so `toolDone`
            // can find the right bubble even if we synthesized
            // a new id (see the `toolDone` branch below).
            if (incoming.isNotEmpty && incoming != toolId) {
              _transportToUiToolCallId[assistantId] ??= <String, String>{};
              _transportToUiToolCallId[assistantId]![incoming] = toolId;
            }
            controller.add(null);
          }
        } else if (event.type == 'toolDone') {
          final s = _activeSession;
          if (s != null) {
            // Resolve which `ToolCall` this `toolDone` event
            // corresponds to. Three cases, in priority order:
            //   1. The transport id maps to a synthesized UI id
            //      we minted in the matching `toolStart` event
            //      (because the transport id collided with an
            //      existing bubble).
            //   2. The transport id matches a `ToolCall` directly
            //      (the common case — server-generated unique
            //      ids, or the local LLM path after
            //      `resolveToolCallId`).
            //   3. Fallback: the orchestrator processes tool
            //      calls sequentially, so the `toolDone` event
            //      updates the *last running* `ToolCall` on the
            //      assistant message. This is what catches the
            //      case where the transport emitted a completely
            //      empty id AND we somehow lost the mapping.
            final rawId = event.toolId ?? '';
            final mapping = _transportToUiToolCallId[assistantId];
            String toolId = (mapping != null && mapping.containsKey(rawId))
                ? mapping[rawId]!
                : (rawId.isNotEmpty ? rawId : '');
            if (toolId.isEmpty ||
                !s.messages
                    .firstWhere(
                      (m) => m.id == assistantId,
                      orElse: () => s.messages.first,
                    )
                    .toolCalls
                    .any((tc) => tc.id == toolId)) {
              final assistant = s.messages.firstWhere(
                (m) => m.id == assistantId,
                orElse: () => s.messages.first,
              );
              final lastRunning = assistant.toolCalls.lastWhere(
                (tc) => tc.isRunning,
                orElse: () => assistant.toolCalls.isEmpty
                    ? ToolCall(id: '', name: '', arguments: '')
                    : assistant.toolCalls.last,
              );
              toolId = lastRunning.id;
              if (toolId.isEmpty) toolId = _uuid.v4();
            }
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
            // Drop the mapping entry once the tool call is
            // terminal so the map doesn't grow without bound
            // across long sessions.
            mapping?.remove(rawId);
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
          if (!completer.isCompleted) completer.complete();
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
        final cur2 = _activeSession;
        if (cur2 != null) {
          _storage.sessions.save(cur2);
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
    final saveCur = _activeSession;
    if (saveCur != null) {
      await _storage.sessions.save(saveCur);
    }
    refreshSessionList();
    if (!_disposed) notifyListeners();
  }

  /// Stops the current generation immediately. Cancels the stream
  /// subscription, aborts any in-flight tool calls, terminates the
  /// orchestrator loop, and resets to the user-sendable state.
  void stopGeneration() {
    if (!_sending) return;
    // Abort the orchestrator so it doesn't start new rounds / execute
    // more tools.
    _orchestrator.cancel();
    // Resolve pending ask_user completers so the orchestrator's
    // tool-execution awaits don't hang forever.
    for (final c in _pendingAskUser.values) {
      if (!c.isCompleted) {
        c.completeError(ToolException('generation stopped by user'));
      }
    }
    _pendingAskUser.clear();
    // Cancel the stream subscription — no more events will be
    // processed by ChatProvider.
    _streamSub?.cancel();
    _streamSub = null;
    // Mark the in-flight assistant message as done (remove streaming
    // flag, add a truncated marker).
    final s = _activeSession;
    if (s != null && s.messages.isNotEmpty) {
      final last = s.messages.last;
      if (last.role == MessageRole.assistant && last.streaming) {
        final truncated = last.content.isEmpty
            ? ''
            : '${last.content}\n\n*(stopped)*';
        _replaceMessages([
          for (var i = 0; i < s.messages.length; i++)
            if (i == s.messages.length - 1)
              last.copyWith(content: truncated, streaming: false)
            else
              s.messages[i],
        ]);
      }
    }
    _sending = false;
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
