import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/chat_session.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/image_service.dart';
import '../services/local_llm_service.dart';
import '../services/storage_service.dart';
import '../services/tool_orchestrator.dart';
import '../services/tool_service.dart';
import 'settings_provider.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider(
    this._storage,
    this._api,
    this._tools,
    this._images,
    this._localLlm,
    this._settings,
  ) {
    _restoreActiveSession();
  }

  final StorageService _storage;
  final ApiService _api;
  final ToolService _tools;
  final ImageService _images;
  final LocalLlmService _localLlm;
  final SettingsProvider _settings;
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

  String _buildSystemPrompt() {
    final buffer = StringBuffer();
    final role = _settings.activeRole;
    if (role != null && role.systemPrompt.isNotEmpty) {
      buffer.writeln(role.systemPrompt);
      buffer.writeln();
    }
    final skills = _settings.activeSkills;
    if (skills.isNotEmpty) {
      buffer.writeln('你可以参考以下技能:');
      for (final s in skills) {
        buffer.writeln('## ${s.name}');
        if (s.description.isNotEmpty) buffer.writeln(s.description);
        if (s.content.isNotEmpty) buffer.writeln(s.content);
        buffer.writeln();
      }
    }
    // Encourage the model not to silently end the turn after a
    // tool returns an error result. Without this hint, some
    // (especially reasoning) models treat "the tool answered
    // with stderr" as "I have nothing to add" and emit [DONE]
    // with an empty content delta, which the user sees as a
    // hang or an unhelpful "no response".
    buffer.writeln(
      '当工具返回错误结果(例如命令退出码非零、网络请求失败、'
      '抛出的异常)时,务必在回复中向用户说明错误原因,'
      '并在合适时给出替代方案。不要在工具出错后直接结束本轮。',
    );
    // Hard rule: when the user asks for information only a tool can
    // provide, actually invoke the tool — never paraphrase what the
    // tool would have said. The orchestrator loops, so it's safe to
    // call multiple tools per turn; you don't need to bundle them
    // into one giant call. The system surfaces tool calls as
    // structured function invocations; "I'll call X now" without a
    // matching function call is treated as a protocol violation by
    // the chat UI.
    buffer.writeln(
      '【工具调用规则】当用户提出只能通过工具获取的信息时(例如:'
      '当前时间、抓取某个网页、执行某条命令、获取本地环境、向用户提问),'
      '你必须直接调用对应的工具来获取结果,不要在文字中假装调用、'
      '也不要凭印象回答。同一回合内可以连续调用多个工具,'
      '所有工具结果回来后再综合回答用户。'
      '在文本中描述"我现在要调用 X"而没有真正发出对应的工具调用,'
      '等同于协议错误,会导致回复被截断。',
    );
    buffer.writeln(
      '【长期记忆】你拥有一个 memory 工具,用于跨会话保留对用户有用的信息。'
      '判断标准是"这条信息对未来的对话是否仍有用":'
      '用户的长期偏好、明确表达的禁忌、个人背景、项目信息、用户主动要求记住的内容,'
      '适合写入(create);单次会话的临时指令、上下文噪音、明显是一次性需求的内容,'
      '不要写入。\n'
      '——【写入技巧】create / update 时除 content 外,务必额外给一个 tags: string[] 参数,'
      '尽量多列 3~6 个相关关键词(中英文同义词、别名、上位词、可能用户后续会怎么搜),'
      '这样未来用 search 模糊查询时召回率才高。tags 越丰富,search 越准。\n'
      '——【查询技巧】search 时优先用 keywords: string[] 一次传多个相关词(OR 语义:'
      '任一关键词命中 content 或 tags 即返回),不要只传一个关键词;'
      '可以再叠加 tags: string[] 进一步收窄。如果你完全没线索,先用 list 看一眼。\n'
      '——【其它】content 写成简洁一句话;用户可以在设置页查看 / 编辑 / 删除所有记忆,'
      '因此你不承担"绝不遗忘"的责任。',
    );
    buffer.writeln(
      '【位置】你有一个 location 工具用于获取用户当前位置(经纬度、城市、省份、'
      '国家、时区)。仅在用户问到天气、附近、本地时区、当地信息等明确需要位置的'
      '场景时调用,不要主动询问。移动端用 GPS(需要授权),桌面/Web 用 IP 反查'
      '(城市级精度,无授权)。结果里带 source 字段( gps / ip )表示来源。',
    );
    return buffer.toString().trim();
  }

  /// True on platforms where desktop-only tools (run_command,
  /// get_environment, ...) can actually run. Used to skip the
  /// schema for those tools on web / mobile so the model doesn't
  /// even see them in its tool list.
  bool get _isDesktopPlatform {
    if (kIsWeb) return false;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  /// True on platforms where mobile-only tools (calendar, reminders)
  /// can actually run. Used to skip the schema for those tools on
  /// web / desktop so the model doesn't see tools it can't use.
  bool get _isMobilePlatform {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  List<Map<String, dynamic>> _buildToolsSchema() {
    final tools = _settings.activeTools;
    final list = <Map<String, dynamic>>[];
    for (final t in tools) {
      switch (t.id) {
        case 'fetch_web':
          list.add({
            'type': 'function',
            'function': {
              'name': 'fetch_web',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'url': {
                    'type': 'string',
                    'description': '要获取的网址,必须包含协议 (http:// 或 https://)',
                  },
                },
                'required': ['url'],
              },
            },
          });
          break;
        case 'current_time':
          list.add({
            'type': 'function',
            'function': {
              'name': 'current_time',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': const <String, dynamic>{},
                'additionalProperties': false,
              },
            },
          });
          break;
        case 'ask_user':
          list.add({
            'type': 'function',
            'function': {
              'name': 'ask_user',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'question': {'type': 'string', 'description': '要向用户提出的问题'},
                  'options': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description': '用户可选择的选项(至少 2 个)',
                    'minItems': 2,
                  },
                  'multi_select': {
                    'type': 'boolean',
                    'description': '是否允许多选,默认 false (单选)',
                    'default': false,
                  },
                },
                'required': ['question', 'options'],
              },
            },
          });
          break;
        case 'run_command':
          // The tool service throws on non-desktop; don't even hand
          // the schema to the model on those platforms.
          if (!_isDesktopPlatform) break;
          list.add({
            'type': 'function',
            'function': {
              'name': 'run_command',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'command': {
                    'type': 'string',
                    'description': '要执行的 shell 命令(通过系统 shell 运行)',
                  },
                  'cwd': {'type': 'string', 'description': '工作目录,可选,默认当前目录'},
                  'timeout_seconds': {
                    'type': 'integer',
                    'description': '超时秒数,默认 30,超时后进程会被 kill',
                    'default': 30,
                    'minimum': 1,
                    'maximum': 600,
                  },
                },
                'required': ['command'],
              },
            },
          });
          break;
        case 'get_environment':
          if (!_isDesktopPlatform) break;
          list.add({
            'type': 'function',
            'function': {
              'name': 'get_environment',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': const <String, dynamic>{},
                'additionalProperties': false,
              },
            },
          });
          break;
        case 'calendar':
          if (!_isMobilePlatform) break;
          list.add({
            'type': 'function',
            'function': {
              'name': 'calendar',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': ['list', 'get', 'create', 'update', 'delete'],
                    'description': '操作类型',
                  },
                  'id': {
                    'type': 'string',
                    'description': 'get/update/delete 时必填',
                  },
                  'title': {
                    'type': 'string',
                    'description': 'create/update 时事件标题',
                  },
                  'start_ms': {
                    'type': 'integer',
                    'description': 'create/update 时事件开始时间 (Unix 毫秒)',
                  },
                  'end_ms': {
                    'type': 'integer',
                    'description': 'create/update 时事件结束时间 (Unix 毫秒),可选',
                  },
                  'notes': {'type': 'string', 'description': '事件备注,可选'},
                  'location': {'type': 'string', 'description': '事件地点,可选'},
                  'alarm_minutes': {
                    'type': 'integer',
                    'description': '提前多少分钟提醒,可选',
                  },
                  'from': {
                    'type': 'integer',
                    'description': 'list 时窗口起始时间 (Unix 毫秒)',
                  },
                  'to': {
                    'type': 'integer',
                    'description': 'list 时窗口结束时间 (Unix 毫秒)',
                  },
                  'max': {
                    'type': 'integer',
                    'description': 'list 时最多返回条数,默认 50',
                    'default': 50,
                  },
                },
                'required': ['action'],
              },
            },
          });
          break;
        case 'reminders':
          if (!_isMobilePlatform) break;
          list.add({
            'type': 'function',
            'function': {
              'name': 'reminders',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': ['list', 'create', 'complete', 'update', 'delete'],
                    'description': '操作类型',
                  },
                  'id': {
                    'type': 'string',
                    'description': 'complete/update/delete 时必填',
                  },
                  'title': {
                    'type': 'string',
                    'description': 'create/update 时标题',
                  },
                  'notes': {'type': 'string', 'description': '备注,可选'},
                  'due_ms': {
                    'type': 'integer',
                    'description': '截止时间 (Unix 毫秒),可选',
                  },
                  'include_completed': {
                    'type': 'boolean',
                    'description': 'list 时是否包含已完成,默认 false',
                    'default': false,
                  },
                  'max': {
                    'type': 'integer',
                    'description': 'list 时最多返回条数,默认 50',
                    'default': 50,
                  },
                },
                'required': ['action'],
              },
            },
          });
          break;
        case 'notes':
          list.add({
            'type': 'function',
            'function': {
              'name': 'notes',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': ['list', 'get', 'create', 'update', 'delete'],
                    'description': '操作类型',
                  },
                  'id': {
                    'type': 'string',
                    'description': 'get/update/delete 时必填',
                  },
                  'title': {
                    'type': 'string',
                    'description': 'create/update 时标题',
                  },
                  'content': {
                    'type': 'string',
                    'description': 'create/update 时正文',
                  },
                  'keyword': {
                    'type': 'string',
                    'description': 'list 时可选的标题/内容关键词',
                  },
                  'max': {
                    'type': 'integer',
                    'description': 'list 时最多返回条数,默认 50',
                    'default': 50,
                  },
                },
                'required': ['action'],
              },
            },
          });
          break;
        case 'tasks':
          list.add({
            'type': 'function',
            'function': {
              'name': 'tasks',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': [
                      'list',
                      'get',
                      'create',
                      'complete',
                      'update',
                      'delete',
                    ],
                    'description': '操作类型',
                  },
                  'id': {
                    'type': 'string',
                    'description': 'get/complete/update/delete 时必填',
                  },
                  'title': {
                    'type': 'string',
                    'description': 'create/update 时标题',
                  },
                  'notes': {
                    'type': 'string',
                    'description': 'create/update 时备注,可选',
                  },
                  'due_ms': {
                    'type': 'integer',
                    'description': '截止时间 (Unix 毫秒),可选',
                  },
                  'include_completed': {
                    'type': 'boolean',
                    'description': 'list 时是否包含已完成,默认 false',
                    'default': false,
                  },
                  'max': {
                    'type': 'integer',
                    'description': 'list 时最多返回条数,默认 50',
                    'default': 50,
                  },
                },
                'required': ['action'],
              },
            },
          });
          break;
        case 'memory':
          list.add({
            'type': 'function',
            'function': {
              'name': 'memory',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': [
                      'list',
                      'search',
                      'get',
                      'create',
                      'update',
                      'delete',
                      'delete_batch',
                    ],
                    'description': '操作类型',
                  },
                  'id': {
                    'type': 'string',
                    'description': 'get/update/delete 时必填',
                  },
                  'keywords': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description':
                        'search 时首选字段。多个关键词任一命中 content 或 tags 即返回(OR 语义)。',
                  },
                  'keyword': {
                    'type': 'string',
                    'description': 'search 时单关键词的兼容写法(等价于 keywords=["…"])',
                  },
                  'tags': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description':
                        'search 时附加过滤:只返回 tags 与此列表有任一交集的记忆;create/update 时是写入的关键词标签,便于后续模糊查找。',
                  },
                  'content': {
                    'type': 'string',
                    'description':
                        'create 时必填,尽量生成多个关键词,便于读取记忆模糊匹配;update 时可选(同时改 content 时填)',
                  },
                  'ids': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description': 'delete_batch 时必填,记忆 id 列表',
                  },
                  'max': {
                    'type': 'integer',
                    'description': 'list/search 时最多返回条数,默认 20',
                    'default': 20,
                  },
                },
                'required': ['action'],
              },
            },
          });
          break;
        case 'location':
          list.add({
            'type': 'function',
            'function': {
              'name': 'location',
              'description': t.description,
              'parameters': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': ['get'],
                    'description': '操作类型,固定 get',
                  },
                  'timeout_ms': {
                    'type': 'integer',
                    'description': '超时毫秒,默认 10000',
                    'default': 10000,
                    'minimum': 1000,
                    'maximum': 60000,
                  },
                },
                'required': const <String>[],
              },
            },
          });
          break;
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
        return await _tools.fetchWeb(url);
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
      default:
        throw ToolException('unknown tool: $name');
    }
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

    final systemPrompt = _buildSystemPrompt();
    final tools = _buildToolsSchema();

    bool updated = false;
    StreamSubscription<StreamEvent>? sub;
    final controller = StreamController<void>();
    final completer = Completer<void>();

    final stream = useLocal
        ? _localLlm.streamChat(
            provider: localProvider!,
            systemPrompt: systemPrompt,
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
            systemPrompt: systemPrompt.isEmpty ? null : systemPrompt,
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
