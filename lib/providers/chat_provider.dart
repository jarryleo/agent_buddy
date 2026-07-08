import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/message.dart';
import '../services/api_service.dart';
import '../services/image_service.dart';
import '../services/storage_service.dart';
import '../services/tool_service.dart';
import 'settings_provider.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider(
    this._storage,
    this._api,
    this._tools,
    this._images,
    this._settings,
  ) {
    _messages = _storage.loadMessages();
  }

  final StorageService _storage;
  final ApiService _api;
  final ToolService _tools;
  final ImageService _images;
  final SettingsProvider _settings;
  final _uuid = const Uuid();

  List<ChatMessage> _messages = [];
  bool _sending = false;
  bool _disposed = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;

  Future<void> clearMessages() async {
    _messages = [];
    await _storage.saveMessages(_messages);
    notifyListeners();
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
    return buffer.toString().trim();
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
      }
    }
    return list;
  }

  Future<String> _onToolCall(Map<String, dynamic> toolCall) async {
    final name = toolCall['name'] as String? ?? '';
    final args = (toolCall['arguments'] as Map?)?.cast<String, dynamic>() ??
        const {};
    switch (name) {
      case 'fetch_web':
        final url = args['url'] as String? ?? '';
        if (url.isEmpty) {
          throw ToolException('url is required');
        }
        return await _tools.fetchWeb(url);
      case 'current_time':
        return await _tools.currentTime();
      default:
        throw ToolException('unknown tool: $name');
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
    final provider = _settings.activeProvider;
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
    final model = provider.selectedModel ??
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
        try {
          dataUrls.add(await _images.toBase64DataUrl(path));
        } catch (e) {
          // Skip this image silently rather than failing the whole
          // turn; the user can re-send if needed.
        }
      }
      requestMessages.add(
        ChatRequestMessage(
          role: m.role,
          content: m.content,
          imageDataUrls: dataUrls,
        ),
      );
    }

    final systemPrompt = _buildSystemPrompt();
    final tools = _buildToolsSchema();

    bool updated = false;
    StreamSubscription<StreamEvent>? sub;
    final controller = StreamController<void>();
    final completer = Completer<void>();

    sub = _api
        .streamChat(
      provider: provider,
      model: model,
      messages: requestMessages,
      systemPrompt: systemPrompt.isEmpty ? null : systemPrompt,
      tools: tools.isEmpty ? null : tools,
      onToolCall: _onToolCall,
    )
        .listen((event) {
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
      } else if (event.type == 'done') {
        completer.complete();
      }
    }, onError: (e) {
      final idx = _messages.indexWhere((m) => m.id == assistantId);
      if (idx >= 0) {
        final errText = l10n.messageErrorPrefix(e.toString());
        _messages = [
          for (final mm in _messages)
            if (mm.id == assistantId)
              mm.copyWith(
                content: mm.content.isEmpty ? errText : '${mm.content}\n\n$errText',
              )
            else
              mm,
        ];
        controller.add(null);
      }
      if (!completer.isCompleted) completer.complete();
    });

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
    _disposed = true;
    super.dispose();
  }
}
