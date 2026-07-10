import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
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
    _messages = _storage.loadMessages();
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

  List<ChatMessage> _messages = [];
  bool _sending = false;
  bool _disposed = false;

  /// Pending `ask_user` tool calls. When the model invokes ask_user
  /// we drop a [Completer] here keyed by the tool-call id; the message
  /// bubble's inline options call [resolveAskUser] when the user picks,
  /// which completes the future and unblocks the streaming `await`.
  final Map<String, Completer<String>> _pendingAskUser = {};

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;

  Future<void> clearMessages() async {
    // Fail any in-flight ask_user prompts so the stream doesn't stay
    // paused waiting for a user response that will never come.
    for (final c in _pendingAskUser.values) {
      if (!c.isCompleted) c.completeError(ToolException('chat cleared'));
    }
    _pendingAskUser.clear();
    _messages = [];
    await _storage.saveMessages(_messages);
    notifyListeners();
  }

  /// Called by the message bubble's inline option chips when the user
  /// picks. Unblocks the streaming `await` on this tool call.
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
      }
    }
    return list;
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
        _messages = [
          for (final m in _messages)
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
        ];
        notifyListeners();
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
      default:
        throw ToolException('unknown tool: $name');
    }
  }

  /// Re-runs a single failed tool call from a finished assistant
  /// message. The tool is executed once, the in-place `ToolCall` is
  /// updated with the new result, and a synthetic user message is
  /// appended so the user can send a new turn (or we can trigger
  /// one immediately) that feeds the new result back to the model.
  ///
  /// We deliberately do NOT auto-trigger a follow-up turn from
  /// here: the model's previous turn already produced `[DONE]`, so
  /// re-running it would be ambiguous. The user explicitly clicking
  /// "Retry" is the trigger to add a new user turn that includes
  /// the new tool result in the history.
  Future<void> retryToolCall(
    BuildContext context,
    String assistantId,
    String toolId,
  ) async {
    if (_sending) return;
    final l10n = AppLocalizations.of(context);
    final idx = _messages.indexWhere((m) => m.id == assistantId);
    if (idx < 0) return;
    final assistant = _messages[idx];
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
    _messages = [
      for (final m in _messages)
        if (m.id == assistantId)
          m.copyWith(
            toolCalls: [
              for (var i = 0; i < m.toolCalls.length; i++)
                if (i == tcIdx) updatedTool else m.toolCalls[i],
            ],
          )
        else
          m,
    ];
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
    final syntheticCall = {
      'id': tc.id,
      'name': tc.name,
      'arguments': argsMap,
    };
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
    _messages = [
      for (final m in _messages)
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
    ];
    await _storage.saveMessages(_messages);
    notifyListeners();

    if (success) {
      // Surface the new result as a user-facing system note so the
      // model picks it up on the next user turn. We use a real user
      // message (not an internal channel) so the retry semantics are
      // obvious in the chat history and the model treats it as
      // fresh context.
      final note = l10n.toolCallRetryNote(tc.name, toolResult);
      _messages = [
        ..._messages,
        ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.user,
          content: note,
        ),
      ];
      await _storage.saveMessages(_messages);
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
        _messages = [
          ..._messages,
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: l10n.chatNoProvider,
          ),
        ];
        await _storage.saveMessages(_messages);
        notifyListeners();
        return;
      }
    } else {
      if (provider == null) {
        _messages = [
          ..._messages,
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: l10n.chatNoProvider,
          ),
        ];
        await _storage.saveMessages(_messages);
        notifyListeners();
        return;
      }
      final model =
          provider.selectedModel ??
          (provider.models.isNotEmpty ? provider.models.first : null);
      if (model == null) {
        _messages = [
          ..._messages,
          ChatMessage(
            id: _uuid.v4(),
            role: MessageRole.assistant,
            content: l10n.chatNoModel,
          ),
        ];
        await _storage.saveMessages(_messages);
        notifyListeners();
        return;
      }
    }

    final userMsg = ChatMessage(
      id: _uuid.v4(),
      role: MessageRole.user,
      content: trimmed,
      imagePaths: List.unmodifiable(imagePaths),
    );
    final assistantId = _uuid.v4();
    final assistantMsg = ChatMessage(
      id: assistantId,
      role: MessageRole.assistant,
      content: '',
      streaming: true,
    );
    _messages = [..._messages, userMsg, assistantMsg];
    _sending = true;
    await _storage.saveMessages(_messages);
    notifyListeners();

    // Build request messages, converting any local image paths to
    // base64 data URLs just-in-time so we don't keep huge blobs in
    // memory. The user message's text (if any) is preserved; if the
    // user sent only images, the API will receive an image-only
    // content array which both OpenAI and Anthropic accept.
    final requestMessages = <ChatRequestMessage>[];
    for (final m in _messages) {
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
          final idx = _messages.indexWhere((m) => m.id == assistantId);
          if (idx >= 0) {
            final toolId = event.toolId ?? '';
            _messages = [
              for (final mm in _messages)
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
            ];
            controller.add(null);
          }
        } else if (event.type == 'toolDone') {
          final idx = _messages.indexWhere((m) => m.id == assistantId);
          if (idx >= 0) {
            final toolId = event.toolId ?? '';
            final now = DateTime.now();
            _messages = [
              for (final mm in _messages)
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
            ];
            controller.add(null);
          }
        } else if (event.type == 'reasoning' && event.thinkingDelta != null) {
          final idx = _messages.indexWhere((m) => m.id == assistantId);
          if (idx >= 0) {
            _messages = [
              for (final mm in _messages)
                if (mm.id == assistantId)
                  mm.copyWith(thinking: mm.thinking + event.thinkingDelta!)
                else
                  mm,
            ];
            if (!updated) {
              updated = true;
            }
            controller.add(null);
          }
        } else if (event.type == 'content' && event.contentDelta != null) {
          final idx = _messages.indexWhere((m) => m.id == assistantId);
          if (idx >= 0) {
            _messages = [
              for (final mm in _messages)
                if (mm.id == assistantId)
                  mm.copyWith(content: mm.content + event.contentDelta!)
                else
                  mm,
            ];
            if (!updated) {
              updated = true;
            }
            controller.add(null);
          }
        } else if (event.type == 'error') {
          final idx = _messages.indexWhere((m) => m.id == assistantId);
          if (idx >= 0) {
            final errText = l10n.messageErrorPrefix(event.error ?? '');
            _messages = [
              for (final mm in _messages)
                if (mm.id == assistantId)
                  mm.copyWith(
                    content: mm.content.isEmpty
                        ? errText
                        : '${mm.content}\n\n$errText',
                  )
                else
                  mm,
            ];
            controller.add(null);
          }
          if (!completer.isCompleted) completer.complete();
        } else if (event.type == 'done') {
          completer.complete();
        }
      },
      onError: (e) {
        final idx = _messages.indexWhere((m) => m.id == assistantId);
        if (idx >= 0) {
          final errText = l10n.messageErrorPrefix(e.toString());
          _messages = [
            for (final mm in _messages)
              if (mm.id == assistantId)
                mm.copyWith(
                  content: mm.content.isEmpty
                      ? errText
                      : '${mm.content}\n\n$errText',
                )
              else
                mm,
          ];
          controller.add(null);
        }
        if (!completer.isCompleted) completer.complete();
      },
    );

    // Throttle notifyListeners to ~80ms during streaming and debounce
    // persistence to 300ms, so we don't trigger excessive rebuilds while
    // the AI is streaming tokens.
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
        _storage.saveMessages(_messages);
      });
    });

    await completer.future;
    await sub.cancel();
    await controller.close();
    persistTimer?.cancel();
    _messages = [
      for (final m in _messages)
        if (m.id == assistantId) m.copyWith(streaming: false) else m,
    ];
    _sending = false;
    await _storage.saveMessages(_messages);
    if (!_disposed) notifyListeners();
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
