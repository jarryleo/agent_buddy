import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/chat_session.dart';
import '../models/download.dart';
import '../models/edited_image.dart';
import '../models/file_attachment.dart';
import '../models/file_type.dart';
import '../models/local_provider.dart';
import '../models/mcp_provider.dart';
import '../models/message.dart';
import '../models/provider.dart';
import '../models/skill.dart';
import '../models/timer_task.dart';
import '../services/api_service.dart';
import '../services/download_service.dart';
import '../services/file_attachment_service.dart';
import '../services/image_service.dart';
import '../services/local_llm_service.dart';
import '../services/storage_service.dart';
import '../services/sub_agent_service.dart';
import '../services/timer_service.dart';
import '../services/tool_orchestrator.dart';
import '../services/tool_service.dart';
import '../services/tools/sub_agent_tool.dart';
import '../services/tools/tool_registry.dart';
import 'settings_provider.dart';

/// Internal status of a single streaming turn attempt, returned
/// by `ChatProvider._runAssistantTurnStreamAttempt` to its
/// orchestrator. Three terminal possibilities:
///
///   * [success]     — the stream produced at least one `done`
///                     event and the bubble is finalized
///                     (streaming=false, metrics stamped).
///   * [hardError]   — a non-retryable error surfaced (auth
///                     failure, validation error, …). The
///                     message body carries the localized
///                     "出错了: …" text and the bubble is
///                     finalized.
///   * [retryable]   — a transient network error occurred (the
///                     canonical example is `ClientException:
///                     Connection closed before full header was
///                     received` against OpenRouter). The bubble
///                     carries the auto-retry state and the
///                     orchestrator is supposed to schedule the
///                     next attempt on the exponential-backoff
///                     schedule. No finalization happens here;
///                     the orchestrator owns the bubble's state
///                     until the chain unwinds.
enum _TurnOutcomeKind { success, hardError, retryable }

class _TurnOutcome {
  final _TurnOutcomeKind kind;
  final String? error;
  const _TurnOutcome._(this.kind, this.error);
  static const _TurnOutcome success = _TurnOutcome._(
    _TurnOutcomeKind.success,
    null,
  );
  factory _TurnOutcome.hardError(String err) =>
      _TurnOutcome._(_TurnOutcomeKind.hardError, err);
  factory _TurnOutcome.retryable(String err) =>
      _TurnOutcome._(_TurnOutcomeKind.retryable, err);
}

/// Builds the always-on base system prompt for a chat turn.
///
/// Kept as a top-level pure function (instead of a method on
/// [ChatProvider]) so the prompt contents are directly unit-testable
/// without spinning up the provider and its 8+ collaborators. The
/// per-tool reminders used to live inline in this string; on a
/// 4K-context local GGUF that ate ~1.5K tokens of every
/// conversation before the model saw a single user word — a major
/// source of the "降智" symptom on small contexts. The full content
/// now lives behind the builtin `tool_usage` skill (see
/// [BuiltinSkills.all]), which the model loads on demand via
/// `load_skill`. This prompt only carries the short summary and a
/// pointer to the skill, plus the two environment hints that
/// genuinely need to be in every turn: the active working directory
/// and the count of MCP servers the model can call.
@visibleForTesting
String buildBaseSystemPrompt({
  String? workingDirectory,
  int enabledMcpServerCount = 0,
}) {
  final workingDirectoryHint = workingDirectory == null
      ? ''
      : '\n- 默认工作目录: $workingDirectory。file / run_command 的相对路径都基于此目录。';
  final mcpHint = enabledMcpServerCount > 0
      ? '\n'
            '- MCP 工具(名称以 mcp__ 开头):已启用 $enabledMcpServerCount 个 MCP 服务器,'
            '工具的 schema 就是参数说明,按需调用即可。'
      : '';
  return '你是一个有用、诚实的助手。\n'
      '\n'
      '## 核心规则\n'
      '1. 不知道就必须用工具查,禁止瞎编。必须真的发出 function_call,别装样子。\n'
      '2. 同一轮可以连续调多个工具,等全部结果回来再统一回复。\n'
      '3. 工具报错了就跟用户说明原因,给个替代方案,别直接完事。\n'
      '4. 回复简洁,别啰嗦。\n'
      '\n'
      '## 工具使用\n'
      '- 每个工具的最终参数以 function schema 为准(列表里的 "parameters")。\n'
      '- 最佳实践、推荐用法、坑点都在技能"工具使用提示"里。'
      '第一次涉及某个工具、或结果不像预期时,先 load_skill(skill_name: "工具使用提示") 看一眼。\n'
      '- 工具调用失败返回的是软错误时(比如 cancelled / not_found / permission_denied),'
      '根据 message 给用户讲清楚,然后给个替代方案,不要直接放弃。\n'
      '\n'
      '完整用法和并发模式见 load_skill(skill_name: "工具使用提示")。'
      '$workingDirectoryHint$mcpHint';
}

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

  /// Periodic 1-second ticker that drives the auto-retry
  /// countdown UI. Started by [_setRetryStateOnMessage] the
  /// first time any assistant message enters the retry state
  /// and stopped when no messages have a pending retry. The
  /// ticker only exists while at least one message is waiting
  /// to retry, so its overhead while idle is zero.
  Timer? _retryTickTimer;

  /// Coalesces the burst of `notifyListeners` calls the
  /// `subagent` tool's progress callback would otherwise fire
  /// (a chatty sub-agent can call `search` / `fetch_web` several
  /// times in a row). Mirrors the streaming layer's ~80ms
  /// throttle so the chat list doesn't repaint on every event.
  Timer? _subAgentNotifyTimer;

  /// Completer signaled when the orchestrator is currently
  /// parked inside the exponential-backoff wait between retry
  /// attempts. [stopGeneration] completes it so the orchestrator
  /// doesn't have to sit out the remaining 320-second interval
  /// of a backoff when the user taps "stop" mid-retry. Set /
  /// cleared exclusively by [_runAssistantTurn] on the cloud
  /// retry path.
  Completer<void>? _retryWakeup;

  /// Returns `true` when a tool call is parked waiting on a
  /// native UI flow (system file picker, OS permission dialog,
  /// etc.) — i.e. the Dart-side Future won't resolve until the
  /// user interacts with the OS. Today only the `file` tool's
  /// `pick` action qualifies (the bridge parks the call until
  /// the user picks or cancels). Kept as a single switch so
  /// adding new "wait for user" tools is a one-line change.
  bool _isAwaitingUserAction(String toolName, String argumentsJson) {
    if (toolName != 'file') return false;
    try {
      final args = jsonDecode(argumentsJson);
      if (args is! Map) return false;
      return args['action'] == 'pick';
    } on FormatException {
      return false;
    }
  }

  /// Normalize the `options` argument for the `ask_user` tool.
  /// The schema declares a flat `string[]`, but newer models
  /// (and a few existing prompts) emit each option as an object
  /// like `{"label": "A", "description": "..."}` instead of a
  /// bare string. The `List.cast<String>()` Dart idiom is a
  /// *lazy* view — `length` doesn't trigger it, but iterating
  /// the list later (in `MessageBubble._AskUserQuestionCard.build`)
  /// does, and throws
  /// `type 'Map<String, dynamic>' is not a subtype of type 'String'`
  /// mid-render. So we eagerly walk the raw list
  /// once here, coerce each entry to a String, and return a
  /// concrete `List<String>` that the bubble can iterate
  /// safely. Object entries fall back to `label` / `value` /
  /// `text` keys (in that order) so we stay compatible with
  /// the most common variants without making the model learn a
  /// new schema.
  static List<String> _normalizeAskUserOptions(dynamic raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final entry in raw) {
      if (entry == null) continue;
      if (entry is String) {
        if (entry.isNotEmpty) out.add(entry);
        continue;
      }
      if (entry is Map) {
        for (final key in const ['label', 'value', 'text']) {
          final v = entry[key];
          if (v is String && v.isNotEmpty) {
            out.add(v);
            break;
          }
        }
      }
    }
    return out;
  }

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
      baseSystem = buildBaseSystemPrompt(
        workingDirectory: _settings.modelWorkingDirectory,
        enabledMcpServerCount: mcpServers.length,
      );
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

  // -------- Auto-retry / backoff (cloud provider path) --------
  //
  // The third-party model APIs (OpenRouter, Volcano, OpenAI via a
  // routed gateway, …) occasionally drop the TCP connection
  // *before* the response headers arrive, surfacing the failure
  // to Dart as `ClientException: Connection closed before full
  // header was received`. The user wants the chat to silently
  // retry these with exponential backoff (5s → 10s → 20s → …
  // → cap at 320s) until the next attempt succeeds, with the
  // current retry count + countdown showing inside the bubble.
  //
  // The retries are an inner loop around
  // [_runAssistantTurnStreamAttempt] — the latter runs ONE
  // HTTP-streaming attempt and reports whether it ended in
  // success, a hard (non-retryable) error, or a transient
  // network failure that should be retried. On retryable
  // failure we surface the retry state to the bubble and wait
  // for the next backoff window before kicking off another
  // attempt. The chain unwinds once the stream yields content
  // or hits a hard error.
  //
  // Local LLM (llamadart / in-process GGUF) doesn't go through
  // the retry path — see [_runAssistantTurn].

  /// Initial auto-retry delay for the 1st retry (i.e. right after
  /// the FIRST connection failure). Doubles for every subsequent
  /// retry until it hits [_retryMaxBackoff].
  static const Duration _retryInitialBackoff = Duration(seconds: 5);

  /// Cap on the auto-retry delay. The interval plateaus here for
  /// repeated failures on a flaky third-party provider; the user
  /// asked for "无限重试" (infinite retries), so we never stop —
  /// we just don't widen the gap past 5m20s.
  static const Duration _retryMaxBackoff = Duration(seconds: 320);

  /// Computes the auto-retry backoff for [attempt]. `attempt == 1`
  /// = first retry (right after the very first failure),
  /// `attempt == 2` = second retry, etc. The interval doubles each
  /// time and caps at [_retryMaxBackoff]. Pure helper — exposed as
  /// `@visibleForTesting` so the schedule can be unit-tested
  /// without spinning up the full provider.
  @visibleForTesting
  static Duration computeRetryBackoff(int attempt) {
    if (attempt <= 0) return Duration.zero;
    // 5s * 2^(attempt-1), clamped at 320s. Done with millisecond
    // arithmetic on `int` to avoid floating-point rounding — the
    // schedule matters for the UI countdown and we want exact
    // whole-second ticks.
    final ms = _retryInitialBackoff.inMilliseconds;
    var total = ms;
    for (
      var i = 1;
      i < attempt && total < _retryMaxBackoff.inMilliseconds;
      i++
    ) {
      final doubled = total * 2;
      total = doubled > _retryMaxBackoff.inMilliseconds
          ? _retryMaxBackoff.inMilliseconds
          : doubled;
    }
    return Duration(milliseconds: total);
  }

  /// Classifies a stream error string as transient (worth
  /// retrying on the backoff schedule) or hard (auth errors,
  /// validation failures — those should surface immediately
  /// and not be retried forever). Substring match against the
  /// `dart:io` / `http` exception class names plus a few
  /// HTTP 5xx codes that are commonly caused by an
  /// upstream-by-them glitch.
  ///
  /// Exposed as `@visibleForTesting` so the classifier can be
  /// unit-tested against representative error strings without a
  /// running API.
  @visibleForTesting
  static bool isRetryableNetworkError(String error) {
    if (error.isEmpty) return false;
    final e = error.toLowerCase();
    // http / dart:io exception classes (the ones that wrap any
    // socket- or DNS-level glitch into a single string).
    if (e.contains('clientexception') ||
        e.contains('socketexception') ||
        e.contains('handshakeexception') ||
        e.contains('timeoutexception')) {
      return true;
    }
    // Common TCP / DNS messages that don't come with a class
    // prefix but show up verbatim in the message body.
    if (e.contains('connection closed') ||
        e.contains('connection refused') ||
        e.contains('connection reset') ||
        e.contains('failed host lookup') ||
        e.contains('network is unreachable') ||
        e.contains('no address associated with hostname') ||
        e.contains('ssl exception') ||
        e.contains('certificate verify failed')) {
      return true;
    }
    // HTTP 5xx — the user's third-party providers tend to
    // occasionally return 502/503/504 on a flaky edge. The
    // Gemini/Claude/OpenAI-style strings include "HTTP 502:"
    // etc. We deliberately keep this conservative — only the
    // well-known transient codes, NOT plain "HTTP 500:" which
    // can also be a permanent application error.
    if (e.contains('http 502') ||
        e.contains('http 503') ||
        e.contains('http 504') ||
        e.contains('http 524') ||
        e.contains('service unavailable') ||
        e.contains('bad gateway') ||
        e.contains('gateway timeout')) {
      return true;
    }
    return false;
  }

  /// Writes the retry state ([retryAttempt] + [nextRetryAt]) to
  /// the assistant message and ensures the periodic countdown
  /// ticker is running so the bubble UI updates every second.
  /// Idempotent — calling with `attempt <= existing attempt` is
  /// a no-op for the bubble (we don't want to roll the countdown
  /// backwards or rewrite state during a tear-down race).
  void _setRetryStateOnMessage(
    String assistantId,
    int attempt,
    DateTime nextAttemptAt,
  ) {
    final s = _activeSession;
    if (s == null) return;
    _replaceMessages([
      for (final m in s.messages)
        if (m.id == assistantId)
          m.copyWith(
            streaming: false,
            retryAttempt: attempt,
            nextRetryAt: nextAttemptAt,
            // Clear the metrics so the footer doesn't show a
            // garbage TTFT=0s marker from the failed attempt.
            metrics: null,
          )
        else
          m,
    ]);
    _ensureRetryTickTimer();
    notifyListeners();
  }

  /// Strips the retry state from a message (used between
  /// retries — once the wait elapses and the next attempt
  /// begins, the bubble should look like a normal streaming
  /// turn again, not a countdown to one).
  void _clearRetryStateOnMessage(String assistantId) {
    final s = _activeSession;
    if (s == null) return;
    _replaceMessages([
      for (final m in s.messages)
        if (m.id == assistantId)
          m.copyWith(streaming: true, retryAttempt: 0, clearNextRetryAt: true)
        else
          m,
    ]);
    notifyListeners();
  }

  /// Starts the 1-second countdown ticker if it isn't running
  /// already. The ticker ONLY exists while at least one message
  /// has a pending retry; it just calls [notifyListeners] every
  /// second so the bubble UI can recompute its countdown label.
  /// The MessageBubble does the actual `nextRetryAt -
  /// DateTime.now()` math — this provider just drives the
  /// periodic rebuild.
  void _ensureRetryTickTimer() {
    if (_retryTickTimer != null) return;
    if (_disposed) return;
    _retryTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) {
        _retryTickTimer?.cancel();
        _retryTickTimer = null;
        return;
      }
      notifyListeners();
    });
  }

  /// Stops the countdown ticker if no messages are still in
  /// the pending-retry state. Called every time the retry loop
  /// completes (success or terminal hard error) so the ticker
  /// doesn't idle forever.
  void _maybeStopRetryTickTimer() {
    if (_retryTickTimer == null) return;
    final stillPending =
        _activeSession?.messages.any((m) => m.isRetrying) ?? false;
    if (!stillPending) {
      _retryTickTimer?.cancel();
      _retryTickTimer = null;
    }
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
    // load_skill, subagent) are handled directly. Everything else
    // delegates to the tool's own execute method via the registry.
    switch (name) {
      case 'ask_user':
        final question = args['question'] as String? ?? '';
        final options = _normalizeAskUserOptions(args['options']);
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
      case 'subagent':
        return await _onSubAgentCall(context, toolCall, assistantId, args);
      case 'edit_image':
        return await _onEditImageCall(context, toolCall, assistantId, args);
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

  /// Backs the `edit_image` tool. The tool itself is a plain
  /// [ToolBase] that returns a JSON envelope — this wrapper
  /// executes the tool, then parses the envelope and appends
  /// the resulting [EditedImage] to the in-place
  /// [ToolCall.editedImages] so the message bubble can render
  /// the preview + Save affordance immediately.
  ///
  /// Returning the same envelope string lets the standard
  /// `toolDone` event apply it as the model-visible result; we
  /// piggy-back on [applyToolDoneEvent] (which preserves
  /// `editedImages` via copyWith's pass-through) and only
  /// mutate the list when we successfully parse a result.
  Future<String> _onEditImageCall(
    BuildContext context,
    Map<String, dynamic> toolCall,
    String assistantId,
    Map<String, dynamic> args,
  ) async {
    final tool = ToolRegistry.byId('edit_image')!;
    final toolId = toolCall['id'] as String? ?? '';
    final resultStr = await tool.execute(args, _tools);

    // Best-effort parse of the envelope. We tolerate a parse
    // failure (which would be a bug — the envelope is fully
    // under our control) by returning the raw result so the
    // model still sees the tool output.
    try {
      final decoded = jsonDecode(resultStr);
      if (decoded is Map && decoded['ok'] == true && decoded['path'] is String) {
        final edited = EditedImage(
          path: decoded['path'] as String,
          filename: decoded['filename'] as String? ?? 'image',
          width: (decoded['width'] as num?)?.toInt() ?? 0,
          height: (decoded['height'] as num?)?.toInt() ?? 0,
          size: (decoded['size'] as num?)?.toInt() ?? 0,
          format: decoded['format'] as String? ?? 'jpeg',
          action: decoded['action'] as String? ?? '',
          sourceWidth: (decoded['source_width'] as num?)?.toInt(),
          sourceHeight: (decoded['source_height'] as num?)?.toInt(),
          sourceSize: (decoded['source_size'] as num?)?.toInt(),
        );
        _mutateToolCall(assistantId, toolId, (tc) {
          return tc.copyWith(
            editedImages: [...tc.editedImages, edited],
          );
        });
        notifyListeners();
      }
    } catch (_) {
      // Swallow: the model still gets the raw envelope as the
      // result string. The bubble just won't render a preview.
    }

    return resultStr;
  }

  /// Backs the `subagent` tool. Resolves the per-turn transport
  /// (cloud vs local) from the active provider settings, then
  /// delegates to `SubAgentTool.runDelegate` which routes through
  /// the shared `SubAgentService`. Useful report content is mirrored
  /// into the `ToolCall` card while the sub-agent runs.
  Future<String> _onSubAgentCall(
    BuildContext context,
    Map<String, dynamic> toolCall,
    String assistantId,
    Map<String, dynamic> args,
  ) async {
    final action = (args['action'] as String? ?? '').trim();
    // list / get / cancel are pure lookups; the tool handles them
    // directly. delegate is the one that needs the chat
    // provider's transport config.
    if (action != 'delegate') {
      final tool = ToolRegistry.byId('subagent')!;
      return tool.execute(args, _tools);
    }
    final useLocal = _settings.useLocalModel;
    final SubAgentConfig config;
    if (useLocal) {
      final lp = _settings.activeLocalProvider;
      if (lp == null) {
        throw ToolException(
          'subagent.delegate: useLocalModel is on but no local provider is active',
        );
      }
      config = SubAgentConfig(useLocal: true, localProvider: lp);
    } else {
      final p = _settings.activeProvider;
      if (p == null) {
        throw ToolException(
          'subagent.delegate: no active cloud provider configured',
        );
      }
      config = SubAgentConfig(useLocal: false, provider: p);
    }
    final task = (args['task'] as String? ?? '').trim();
    final want = (args['want'] as String? ?? '').trim();
    final ctx = (args['context'] as String? ?? '').trim();
    if (task.isEmpty) {
      throw ToolException(
        'subagent.delegate: "task" is required and must be non-empty',
      );
    }
    if (want.isEmpty) {
      throw ToolException(
        'subagent.delegate: "want" is required and must be non-empty',
      );
    }
    final toolId = toolCall['id'] as String? ?? '';
    final tool = ToolRegistry.byId('subagent')! as SubAgentTool;
    // Mirror the sub-agent's progress into the in-place
    // `ToolCall` card so the user can see the sub-agent working.
    // We re-resolve the assistant message + tool call on every
    // progress event because the orchestrator may have inserted
    // other tool calls in the meantime (though in practice the
    // main turn is silent while the sub-agent runs). The result
    // panel shows the sub-agent's actual REPORT (streaming in
    // live) — not the messy list of intermediate tool calls —
    // because that's the summary the sub-agent hands back to the
    // main agent. See [formatSubAgentSnapshot].
    void mirrorProgress(SubAgentProgress p) {
      final cur = _activeSession;
      if (cur == null) return;
      final terminal =
          p.phase == SubAgentProgressPhase.report ||
          p.phase == SubAgentProgressPhase.failed ||
          p.phase == SubAgentProgressPhase.cancelled;
      _replaceMessages([
        for (final m in cur.messages)
          if (m.id == assistantId)
            m.copyWith(
              toolCalls: [
                for (final tc in m.toolCalls)
                  if (tc.id == toolId)
                    tc.copyWith(
                      result: formatSubAgentSnapshot(p.task),
                      status: switch (p.task.status) {
                        SubAgentStatus.running => ToolCallStatus.running,
                        SubAgentStatus.completed => ToolCallStatus.success,
                        SubAgentStatus.failed => ToolCallStatus.failed,
                        SubAgentStatus.cancelled => ToolCallStatus.failed,
                      },
                      finishedAt: terminal ? DateTime.now() : null,
                    )
                  else
                    tc,
              ],
            )
          else
            m,
      ]);
      // Throttled notify (the streaming layer throttles to ~80ms;
      // mirror that here so we don't spam repaints while the
      // sub-agent hammers search / fetch_web).
      _maybeThrottledNotify();
    }

    final result = await tool.runDelegate(
      services: _tools,
      config: config,
      task: task,
      want: want,
      context: ctx,
      onProgress: mirrorProgress,
    );
    // One last notify so the bubble flips to the terminal state
    // immediately even if the throttle was about to fire.
    if (_subAgentNotifyTimer != null) {
      _subAgentNotifyTimer!.cancel();
      _subAgentNotifyTimer = null;
    }
    notifyListeners();
    return result;
  }

  @visibleForTesting
  static String formatSubAgentSnapshot(SubAgentTask task) {
    switch (task.status) {
      case SubAgentStatus.running:
        final partial = task.report;
        if (partial != null && partial.trim().isNotEmpty) {
          return partial;
        }
        return '';
      case SubAgentStatus.completed:
        final report = task.report;
        if (report == null || report.trim().isEmpty) {
          return SubAgentService.noUsefulResult;
        }
        return report;
      case SubAgentStatus.failed:
        return SubAgentService.noUsefulResult;
      case SubAgentStatus.cancelled:
        return SubAgentService.cancelledResult;
    }
  }

  @visibleForTesting
  static ToolCall applyToolDoneEvent(
    ToolCall toolCall,
    StreamEvent event,
    DateTime finishedAt,
  ) {
    final preserveSubAgentSnapshot =
        toolCall.name == 'subagent' && toolCall.isDone;
    return toolCall.copyWith(
      status: preserveSubAgentSnapshot
          ? toolCall.status
          : (event.toolSuccess ?? false)
          ? ToolCallStatus.success
          : ToolCallStatus.failed,
      result: preserveSubAgentSnapshot ? toolCall.result : event.toolResult,
      error: preserveSubAgentSnapshot ? toolCall.error : event.toolError,
      awaitingUserAction: false,
      finishedAt: finishedAt,
    );
  }

  /// Throttled `notifyListeners` — mirrors the streaming layer's
  /// ~80ms throttle so a noisy sub-agent (e.g. one that fires
  /// five `search` calls in quick succession) doesn't repaint
  /// the chat list five times in a row.
  void _maybeThrottledNotify() {
    _subAgentNotifyTimer ??= Timer(const Duration(milliseconds: 80), () {
      _subAgentNotifyTimer = null;
      if (!_disposed) notifyListeners();
    });
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

  /// Shared streaming turn runner. Builds the request list,
  /// drives the stream, and finalizes the bubble. Used by both
  /// the user-initiated path ([sendMessage]) and the
  /// timer-driven path ([continueWithLastUserMessage]).
  ///
  /// Cloud path also wraps the streaming body in an automatic
  /// retry loop. Transient network failures (the canonical
  /// example is `ClientException: Connection closed before full
  /// header was received` against OpenRouter) trigger an
  /// exponential-backoff retry: 5s → 10s → 20s → 40s → … →
  /// 320s cap, then plateaus. Successful connection in any
  /// attempt clears the retry state — the next failure will
  /// start the schedule over from 5s. The local-LLM path
  /// (in-process GGUF) runs straight through with no retry.
  Future<void> _runAssistantTurn(
    BuildContext context,
    String assistantId,
  ) async {
    final useLocal = _settings.useLocalModel;
    final provider = _settings.activeProvider;
    final localProvider = _settings.activeLocalProvider;

    // Build request messages ONCE — they're identical for
    // every retry attempt.
    final requestMessages = await _buildRequestMessages(
      assistantId: assistantId,
      useLocal: useLocal,
    );
    if (requestMessages == null) {
      // Active session has been torn down between the start of
      // sendMessage and now (rare — only on rapid session
      // switching during the bootstrap). Nothing to stream.
      _sending = false;
      if (!_disposed) notifyListeners();
      return;
    }
    final systemPrompts = _buildSystemPrompts();
    final tools = await _buildToolsSchema();

    if (useLocal) {
      // In-process GGUF — no network involved, so transient
      // network errors do not apply. Single attempt.
      await _runAssistantTurnStreamAttempt(
        // ignore: use_build_context_synchronously
        context: context,
        assistantId: assistantId,
        requestMessages: requestMessages,
        systemPrompts: systemPrompts,
        tools: tools,
        useLocal: true,
        localProvider: localProvider,
        provider: null,
        attempt: 0,
      );
    } else {
      // Cloud. Drive the retry loop. `attempt == 0` is the
      // first try; `attempt == N (>=1)` is the (N+1)-th try
      // after N previous failures. Each iteration:
      //   - body runs one HTTP streaming attempt
      //   - returns success / hardError → break, finalize
      //   - returns retryable         → bump attempt, wait
      //                                `computeRetryBackoff(attempt)`
      //                                seconds, then loop
      var attempt = 0;
      while (!_disposed) {
        final outcome = await _runAssistantTurnStreamAttempt(
          // ignore: use_build_context_synchronously
          context: context,
          assistantId: assistantId,
          requestMessages: requestMessages,
          systemPrompts: systemPrompts,
          tools: tools,
          useLocal: false,
          localProvider: null,
          provider: provider,
          attempt: attempt,
        );
        if (outcome.kind != _TurnOutcomeKind.retryable) break;

        attempt++;
        final delay = computeRetryBackoff(attempt);
        final nextAt = DateTime.now().add(delay);
        _setRetryStateOnMessage(assistantId, attempt, nextAt);
        _ensureRetryTickTimer();

        // Wait for either the backoff interval to elapse or
        // `stopGeneration` to wake us up early. The latter is
        // necessary because the user's "stop" tap otherwise has
        // to wait out the remaining portion of a (potentially
        // up to 320s) backoff interval — they'd be staring at
        // a frozen countdown for minutes.
        final wakeup = Completer<void>();
        _retryWakeup = wakeup;
        Timer(delay, () {
          if (!wakeup.isCompleted) wakeup.complete();
        });
        await wakeup.future;
        if (identical(_retryWakeup, wakeup)) _retryWakeup = null;

        if (_disposed || !_sending) {
          _clearRetryStateOnMessage(assistantId);
          _maybeStopRetryTickTimer();
          _sending = false;
          if (!_disposed) notifyListeners();
          return;
        }

        // Reset the bubble to "actively streaming" state so
        // the user sees the typewriter again rather than a
        // stale countdown.
        _clearRetryStateOnMessage(assistantId);
      }
    }

    // One-shot cleanup that runs regardless of whether the
    // chain unwound via the local single-attempt path, the
    // cloud success path, the cloud hard-error path, or the
    // user-stopped-during-wait path.
    _sending = false;
    _maybeStopRetryTickTimer();
    final saveCur = _activeSession;
    if (saveCur != null) {
      await _storage.sessions.save(saveCur);
    }
    refreshSessionList();
    if (!_disposed) notifyListeners();
  }

  /// Pulls every persisted user/assistant message out of the
  /// active session — EXCEPT the in-flight assistant
  /// placeholder — and converts them to ChatRequestMessage
  /// objects (translating image paths to base64 data URLs in
  /// the cloud path, preparing file attachments). Returns null
  /// when the active session is gone.
  Future<List<ChatRequestMessage>?> _buildRequestMessages({
    required String assistantId,
    required bool useLocal,
  }) async {
    final cur = _activeSession;
    if (cur == null) return null;
    final out = <ChatRequestMessage>[];
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
      // Surface the local file paths of any attached images to
      // the model in the user-visible content. Cloud APIs receive
      // the images inline as base64, but the file paths are the
      // only handle the model can use to feed back into tools
      // that read raw bytes (e.g. `edit_image` / `file` /
      // `subagent`). Without this header, the model would have
      // to guess the path — or copy-paste the base64 back into
      // a tool call, neither of which works.
      final augmentedContent = _augmentContentWithImagePaths(
        m.content,
        m.imagePaths,
      );
      out.add(
        ChatRequestMessage(
          role: m.role,
          content: augmentedContent,
          imageDataUrls: dataUrls,
          // Always carry the paths even on the cloud path so
          // the wire-builder can fall back to a "path header"
          // when the model doesn't accept images inline (see
          // `ApiService._buildOpenAIMessages`).
          imagePaths: List.unmodifiable(m.imagePaths),
          fileAttachments: List.unmodifiable(preparedFiles),
        ),
      );
    }
    return out;
  }

  /// Augment [content] with a trailing "Attached images:"
  /// block that lists the absolute local paths of any attached
  /// images. Returns [content] unchanged when no images are
  /// attached.
  ///
  /// The block uses a stable format the model can copy-paste
  /// verbatim into the `edit_image` tool's `image_path` arg
  /// without any quoting / escaping: just one absolute path
  /// per line. The English header is intentional — even when
  /// the chat is in Chinese, the path strings themselves have
  /// to be byte-exact, and anchoring on the English keyword
  /// lets the model regex them out cleanly.
  static String _augmentContentWithImagePaths(
    String content,
    List<String> imagePaths,
  ) {
    if (imagePaths.isEmpty) return content;
    final buf = StringBuffer();
    if (content.isNotEmpty) {
      buf.write(content);
      buf.write('\n\n');
    }
    buf.write('Attached images (local file paths — pass to `edit_image.image_path` '
        'or `file.read` when needed):');
    for (final p in imagePaths) {
      buf.write('\n- $p');
    }
    return buf.toString();
  }

  /// Test seam for [_augmentContentWithImagePaths]. Exposed
  /// as a public static so unit tests can pin down the exact
  /// path-header format without spinning up the full
  /// ChatProvider. Returns the same string as the private
  /// helper above; the public name just lets `@visibleForTesting`
  /// flag it.
  @visibleForTesting
  static String augmentContentWithImagePaths(
    String content,
    List<String> imagePaths,
  ) =>
      _augmentContentWithImagePaths(content, imagePaths);

  /// Runs ONE streaming turn attempt. Returns the [_TurnOutcome]
  /// so the orchestrator can decide whether to retry on the
  /// exponential-backoff schedule or to finalize the bubble.
  /// The body must NOT set `_sending=false` — that's the
  /// orchestrator's job once the chain unwinds.
  ///
  /// **Retry classification rule** — on `error` event /
  /// `onError` in the cloud path only, the error string is fed
  /// to [isRetryableNetworkError]:
  ///   - matches → return [_TurnOutcome.retryable]; the
  ///               orchestrator schedules the next attempt on
  ///               the exponential-backoff schedule.
  ///   - no match → existing hard-error path (write the
  ///                localized "出错了: …" text into the bubble)
  ///                and return [_TurnOutcome.hardError].
  ///
  /// The same body is reused across the local and the cloud
  /// path; the local path skips the retry branch because the
  /// condition `useLocal == true` short-circuits the
  /// classifier.
  Future<_TurnOutcome> _runAssistantTurnStreamAttempt({
    required BuildContext context,
    required String assistantId,
    required List<ChatRequestMessage> requestMessages,
    required List<String> systemPrompts,
    required List<Map<String, dynamic>> tools,
    required bool useLocal,
    required LocalProvider? localProvider,
    required ModelProvider? provider,
    required int attempt,
  }) async {
    final l10n = AppLocalizations.of(context);
    bool updated = false;

    // Per-turn metrics (TTFT, tokens/sec, token counts). The
    // turnStartedAt timestamp anchors time-to-first-token;
    // firstTokenAt / lastTokenAt are stamped as content (or
    // reasoning) deltas flow through. inputTokens is computed
    // up front from the request payload; outputTokens is
    // incremented token-by-token via the [estimateTokens]
    // heuristic so we don't have to depend on per-protocol
    // usage callbacks (OpenAI/Anthropic SSE doesn't include
    // them by default). The final [MessageMetrics] is written
    // back to the in-place assistant message in the
    // post-stream cleanup block below (only on success /
    // hard-error — retryable outcomes are handled by the
    // orchestrator).
    final turnStartedAt = DateTime.now();
    var inputTokens = 0;
    for (final p in systemPrompts) {
      inputTokens += estimateTokens(p);
    }
    for (final m in requestMessages) {
      inputTokens += estimateTokens(m.content);
      if (m.thinking.isNotEmpty) inputTokens += estimateTokens(m.thinking);
      for (final _ in m.imageDataUrls) {
        // Roughly 85 tokens per low-res image after OpenAI
        // detail=auto downscaling. Round up — image tokens
        // are notoriously hard to estimate exactly, and the
        // footer doesn't claim precise accounting.
        inputTokens += 85;
      }
      for (final f in m.fileAttachments) {
        if (f.textContent != null) {
          inputTokens += estimateTokens(f.textContent!);
        } else {
          // Binary attachments are sent as base64 blobs;
          // cost ~1 token per 4 bytes of original data.
          inputTokens += (f.size + 3) ~/ 4;
        }
      }
    }
    var firstTokenAt = null as DateTime?;
    var lastTokenAt = null as DateTime?;
    var outputTokens = 0;

    final completer = Completer<_TurnOutcome>();
    StreamSubscription<StreamEvent>? sub;
    final controller = StreamController<void>();

    // Single-shot guard: once we've recorded an outcome (any
    // kind), subsequent events from the stream become no-ops.
    // This guards against a late 'content' / 'error' / 'done'
    // event that arrives AFTER we've decided the attempt is
    // retryable — the upstream stream may still flush
    // buffered events after we tear down.
    var outcomeRecorded = false;
    void recordOutcome(_TurnOutcome o) {
      if (outcomeRecorded) return;
      outcomeRecorded = true;
      if (!completer.isCompleted) completer.complete(o);
    }

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
            inlineFileTypes: useLocal
                ? _effectiveLocalInlineFileTypes(localProvider)
                : null,
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
            inlineFileTypes: provider.effectiveSupportedFileTypes,
          );

    _streamSub = sub;
    sub = stream.listen(
      (event) {
        if (outcomeRecorded) return;
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
                        // The file picker's `pick` action is the
                        // canonical example: the Dart-side Future
                        // won't resolve until the user answers the
                        // system picker. Mark it so the bubble can
                        // show a "等待用户操作…" hint instead of a
                        // generic spinner.
                        awaitingUserAction: _isAwaitingUserAction(
                          event.toolName ?? '',
                          event.toolArguments ?? '',
                        ),
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
                          applyToolDoneEvent(tc, event, now)
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
            // Reasoning tokens also count toward TTFT — the
            // user sees the model "thinking", which is the
            // first user-visible signal that the request has
            // landed. Reasoning deltas also contribute to the
            // output-token count so the footer reflects the
            // full work the model did.
            final now = DateTime.now();
            firstTokenAt ??= now;
            lastTokenAt = now;
            outputTokens += estimateTokens(event.thinkingDelta!);
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
            // Content delta is the canonical TTFT trigger.
            // lastTokenAt is stamped on every chunk so the
            // tokens/sec denominator is always the latest
            // possible interval.
            final now = DateTime.now();
            firstTokenAt ??= now;
            lastTokenAt = now;
            outputTokens += estimateTokens(event.contentDelta!);
            controller.add(null);
          }
        } else if (event.type == 'error') {
          // Cloud path: classify as transient BEFORE writing
          // the error to the bubble. A retryable error flips
          // the bubble to "retrying" state and lets the
          // orchestrator schedule another attempt on the
          // exponential-backoff schedule.
          final raw = event.error ?? '';
          if (!useLocal && isRetryableNetworkError(raw)) {
            recordOutcome(_TurnOutcome.retryable(raw));
            _setRetryStateOnMessage(
              assistantId,
              attempt + 1,
              DateTime.now().add(computeRetryBackoff(attempt + 1)),
            );
            return;
          }
          // Hard error path (existing behavior).
          final s = _activeSession;
          if (s != null) {
            final errText = l10n.messageErrorPrefix(raw);
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
          recordOutcome(_TurnOutcome.hardError(raw));
        } else if (event.type == 'done') {
          recordOutcome(_TurnOutcome.success);
        }
      },
      onError: (e) {
        if (outcomeRecorded) return;
        final raw = e.toString();
        if (!useLocal && isRetryableNetworkError(raw)) {
          recordOutcome(_TurnOutcome.retryable(raw));
          _setRetryStateOnMessage(
            assistantId,
            attempt + 1,
            DateTime.now().add(computeRetryBackoff(attempt + 1)),
          );
          return;
        }
        final s = _activeSession;
        if (s != null) {
          final errText = l10n.messageErrorPrefix(raw);
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
        recordOutcome(_TurnOutcome.hardError(raw));
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

    final outcome = await completer.future;
    await sub.cancel();
    await controller.close();
    persistTimer?.cancel();
    final s = _activeSession;
    if (s != null && outcome.kind != _TurnOutcomeKind.retryable) {
      // Stamp the final [MessageMetrics] onto the assistant
      // message before flipping `streaming: false`. The bubble
      // footer reads from [ChatMessage.metrics] — if it's null
      // (e.g. the stream errored before the first chunk), the
      // footer simply renders the timestamp + copy icon with
      // no metric chips, which is the right "nothing to show"
      // state.
      //
      // We snapshot the metrics in a local final so the
      // `for ... if ... else` rebuild is side-effect free —
      // matches the pattern used everywhere else in this
      // method.
      //
      // Skipped on retryable outcomes — those already wrote
      // streaming=false + null metrics into the bubble via
      // [_setRetryStateOnMessage], so re-stamping would
      // overwrite the retry state we just set.
      final finalMetrics = MessageMetrics(
        turnStartedAt: turnStartedAt,
        firstTokenAt: firstTokenAt,
        lastTokenAt: lastTokenAt,
        outputTokens: outputTokens,
        inputTokens: inputTokens,
      );
      _replaceMessages([
        for (final m in s.messages)
          if (m.id == assistantId)
            m.copyWith(streaming: false, metrics: finalMetrics)
          else
            m,
      ]);
    }
    return outcome;
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
    // Wake up any in-flight retry wait so the orchestrator
    // unwinds immediately instead of sitting out the rest of
    // a (potentially 320s) backoff interval.
    final wakeup = _retryWakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
    // Cancel the stream subscription — no more events will be
    // processed by ChatProvider.
    _streamSub?.cancel();
    _streamSub = null;
    // Mark the in-flight assistant message as done (remove streaming
    // flag, add a truncated marker; clear any auto-retry state
    // so the bubble doesn't keep showing a stale countdown).
    final s = _activeSession;
    if (s != null && s.messages.isNotEmpty) {
      final last = s.messages.last;
      if (last.role == MessageRole.assistant) {
        final truncated = (last.streaming || last.isRetrying)
            ? (last.content.isEmpty ? '' : '${last.content}\n\n*(stopped)*')
            : last.content;
        _replaceMessages([
          for (var i = 0; i < s.messages.length; i++)
            if (i == s.messages.length - 1)
              last.copyWith(
                content: truncated,
                streaming: false,
                retryAttempt: 0,
                clearNextRetryAt: true,
              )
            else
              s.messages[i],
        ]);
      }
    }
    _sending = false;
    _maybeStopRetryTickTimer();
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

  /// Derive the file categories the local model can accept inline.
  ///
  /// Local llama.cpp backends can't actually decode arbitrary
  /// binaries (audio/video/PDFs) — only text (the decoder reads
  /// files as text and prepends them to the prompt) and images
  /// (when an mmproj projector is loaded and the engine reports
  /// [LocalLlmService.supportsVision]). So:
  ///
  ///   * `text` is always inline-able — [FileAttachmentService]
  ///     decodes the bytes into a UTF-8 string and we prepend the
  ///     envelope + body to the prompt.
  ///   * `image` is inline-able only when the loaded model has an
  ///     mmproj projector (otherwise the engine would just drop
  ///     the image part on the floor).
  ///   * Everything else (audio / video / document) falls through
  ///     to path-only — the model gets the path header so it can
  ///     use the `file` tool to pull the bytes itself.
  ///
  /// This mirrors the cloud path's behavior without forcing the
  /// user to flip per-type toggles for the local model — the
  /// engine capabilities are the source of truth.
  Set<AgentFileType> _effectiveLocalInlineFileTypes(LocalProvider? lp) {
    final inline = <AgentFileType>{AgentFileType.text};
    if (lp != null && _localLlm.supportsVision) {
      inline.add(AgentFileType.image);
    }
    return Set.unmodifiable(inline);
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

  // -------- Edited-image affordances (called from the message bubble) --------

  /// Copies an edited-image temp file to the user-picked
  /// [destDir]. The temp file is **not** deleted — unlike
  /// [saveDownload], we keep the source so the user can still
  /// preview the image in the bubble after saving (and so the
  /// model can keep referencing it if the user wants a
  /// follow-up edit). Returns the final destination path.
  /// Throws [ToolException] if the temp file is gone (e.g. the
  /// app was restarted between the edit and the save).
  ///
  /// The caller (the bubble's `EditImageCard`) opens a
  /// `FilePicker` dialog first to get `destDir`, then awaits
  /// this method to perform the actual copy.
  Future<String> saveEditedImage({
    required String assistantId,
    required String toolId,
    required String imagePath,
    required String destDir,
  }) async {
    final s = _activeSession;
    if (s == null) {
      throw ToolException('no active session');
    }
    final src = File(imagePath);
    if (!await src.exists()) {
      throw ToolException(
        'edited image is no longer available '
        '(temp file was wiped, probably after an app restart)',
      );
    }
    // Sanitize the filename: strip any path separators the
    // temp-dir helper may have leaked in. We don't let the
    // user pick a destination *name* — only a directory — so
    // the original `filename` carries over verbatim (with
    // separators replaced).
    final rawName = p.basename(imagePath);
    final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var dest = p.join(destDir, safeName);
    var attempt = 1;
    while (await File(dest).exists()) {
      final stem = p.basenameWithoutExtension(safeName);
      final ext = p.extension(safeName);
      dest = p.join(destDir, '$stem ($attempt)$ext');
      attempt++;
      if (attempt > 9999) {
        throw ToolException(
          'could not find a non-clashing filename in $destDir',
        );
      }
    }
    await src.copy(dest);
    return dest;
  }

  @override
  void dispose() {
    for (final c in _pendingAskUser.values) {
      if (!c.isCompleted) {
        c.completeError(ToolException('disposed before user responded'));
      }
    }
    _pendingAskUser.clear();
    // Cancel any pending retry-wait waiter + countdown ticker.
    final wakeup = _retryWakeup;
    if (wakeup != null && !wakeup.isCompleted) wakeup.complete();
    _retryTickTimer?.cancel();
    _retryTickTimer = null;
    _disposed = true;
    super.dispose();
  }
}
