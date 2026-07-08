import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/tool_service.dart';
import 'settings_provider.dart';

class ChatProvider extends ChangeNotifier {
  ChatProvider(this._storage, this._api, this._tools, this._settings) {
    _messages = _storage.loadMessages();
  }

  final StorageService _storage;
  final ApiService _api;
  final ToolService _tools;
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
      if (t.id == 'fetch_web') {
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
      }
    }
    return list;
  }

  Future<String> _onToolCall(Map<String, dynamic> toolCall) async {
    final name = toolCall['name'] as String? ?? '';
    final args = (toolCall['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (name) {
      case 'fetch_web':
        final url = args['url'] as String? ?? '';
        if (url.isEmpty) return '错误: url 不能为空';
        return await _tools.fetchWeb(url);
      default:
        return '错误: 未知工具 $name';
    }
  }

  Future<void> sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _sending) return;
    final provider = _settings.activeProvider;
    if (provider == null) {
      _messages = [
        ..._messages,
        ChatMessage(
          id: _uuid.v4(),
          role: MessageRole.assistant,
          content: '请先在设置中添加并启用一个模型提供商。',
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
          content: '当前提供商没有可用模型,请先在设置中获取模型列表并选择一个模型。',
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

    final requestMessages = _messages
        .where((m) =>
            m.id != assistantId &&
            (m.role == MessageRole.user || m.role == MessageRole.assistant) &&
            m.content.isNotEmpty)
        .map((m) => ChatRequestMessage(role: m.role, content: m.content))
        .toList();

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
      if (event.type == 'reasoning' && event.thinkingDelta != null) {
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
          _messages = [
            for (final mm in _messages)
              if (mm.id == assistantId)
                mm.copyWith(
                  content: mm.content.isEmpty
                      ? '出错了: ${event.error}'
                      : '${mm.content}\n\n出错了: ${event.error}',
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
        _messages = [
          for (final mm in _messages)
            if (mm.id == assistantId)
              mm.copyWith(
                content: mm.content.isEmpty ? '出错了: $e' : '${mm.content}\n\n出错了: $e',
              )
            else
              mm,
        ];
        controller.add(null);
      }
      if (!completer.isCompleted) completer.complete();
    });

    // Throttle persistence + notify: at most every 200ms
    Timer? persistTimer;
    controller.stream.listen((_) {
      if (_disposed) return;
      notifyListeners();
      persistTimer?.cancel();
      persistTimer = Timer(const Duration(milliseconds: 200), () {
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
