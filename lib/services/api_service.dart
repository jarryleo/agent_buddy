import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/message.dart';
import '../models/provider.dart';

class StreamEvent {
  final String type;
  final String text;
  final String? thinkingDelta;
  final String? contentDelta;
  final String? error;
  final bool done;

  // Tool-call fields. Populated when type == 'toolStart' or 'toolDone'.
  final String? toolId;
  final String? toolName;
  final String? toolArguments;
  final String? toolResult;
  final bool? toolSuccess;
  final String? toolError;

  const StreamEvent({
    required this.type,
    this.text = '',
    this.thinkingDelta,
    this.contentDelta,
    this.error,
    this.done = false,
    this.toolId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolSuccess,
    this.toolError,
  });

  factory StreamEvent.error(String msg) =>
      StreamEvent(type: 'error', error: msg);
  factory StreamEvent.done() => const StreamEvent(type: 'done', done: true);
  factory StreamEvent.toolStart({
    required String id,
    required String name,
    required String arguments,
  }) =>
      StreamEvent(
        type: 'toolStart',
        toolId: id,
        toolName: name,
        toolArguments: arguments,
      );
  factory StreamEvent.toolDone({
    required String id,
    required String name,
    required String result,
    required bool success,
    String? error,
  }) =>
      StreamEvent(
        type: 'toolDone',
        toolId: id,
        toolName: name,
        toolResult: result,
        toolSuccess: success,
        toolError: error,
      );
}

class ChatRequestMessage {
  final MessageRole role;
  final String content;
  final String thinking;

  /// Pre-converted `data:image/...;base64,...` URLs for any images
  /// attached to a user message. Empty for text-only messages and for
  /// non-user roles.
  final List<String> imageDataUrls;

  const ChatRequestMessage({
    required this.role,
    required this.content,
    this.thinking = '',
    this.imageDataUrls = const [],
  });
}

class ApiService {
  final http.Client _client = http.Client();

  void dispose() {
    _client.close();
  }

  Future<bool> testConnection(ModelProvider provider) async {
    try {
      switch (provider.protocol) {
        case ProviderProtocol.openai:
          return await _testOpenAI(provider);
        case ProviderProtocol.anthropic:
          return await _testAnthropic(provider);
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _testOpenAI(ModelProvider provider) async {
    final base = provider.baseUrl.endsWith('/')
        ? provider.baseUrl.substring(0, provider.baseUrl.length - 1)
        : provider.baseUrl;
    final url = Uri.parse('$base/v1/models');
    final headers = _openAIHeaders(provider);
    final resp = await _client.get(url, headers: headers).timeout(const Duration(seconds: 15));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  }

  Future<bool> _testAnthropic(ModelProvider provider) async {
    final base = provider.baseUrl.endsWith('/')
        ? provider.baseUrl.substring(0, provider.baseUrl.length - 1)
        : provider.baseUrl;
    final url = Uri.parse('$base/v1/models');
    final headers = _anthropicHeaders(provider);
    final resp = await _client.get(url, headers: headers).timeout(const Duration(seconds: 15));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  }

  Map<String, String> _openAIHeaders(ModelProvider provider) {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${provider.apiKey}',
    };
  }

  Map<String, String> _anthropicHeaders(ModelProvider provider) {
    return {
      'Content-Type': 'application/json',
      'x-api-key': provider.apiKey,
      'anthropic-version': '2023-06-01',
    };
  }

  Future<List<String>> fetchModels(ModelProvider provider) async {
    final base = provider.baseUrl.endsWith('/')
        ? provider.baseUrl.substring(0, provider.baseUrl.length - 1)
        : provider.baseUrl;
    final url = Uri.parse('$base/v1/models');
    final headers = provider.protocol == ProviderProtocol.openai
        ? _openAIHeaders(provider)
        : _anthropicHeaders(provider);
    final resp = await _client.get(url, headers: headers).timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final list = (data['data'] as List?) ?? const [];
    final models = <String>[];
    for (final item in list) {
      if (item is Map && item['id'] is String) {
        models.add(item['id'] as String);
      }
    }
    models.sort();
    return models;
  }

  /// Streams chat completion. Yields StreamEvent chunks.
  /// If [onToolCall] is provided and the model requests a tool, the tool is invoked
  /// and the result is fed back to the model in a follow-up request. The final
  /// [StreamEvent.done] is yielded after the conversation is complete.
  Stream<StreamEvent> streamChat({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
  }) async* {
    switch (provider.protocol) {
      case ProviderProtocol.openai:
        yield* _streamOpenAI(
          provider: provider,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          tools: tools,
          onToolCall: onToolCall,
        );
        break;
      case ProviderProtocol.anthropic:
        yield* _streamAnthropic(
          provider: provider,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          tools: tools,
          onToolCall: onToolCall,
        );
        break;
    }
  }

  Stream<StreamEvent> _streamOpenAI({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
  }) async* {
    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'messages': _buildOpenAIMessages(messages, systemPrompt),
    };
    if (tools != null && tools.isNotEmpty) {
      payload['tools'] = tools;
    }

    final req = http.Request('POST', Uri.parse(provider.fullChatUrl))
      ..headers.addAll(_openAIHeaders(provider))
      ..body = jsonEncode(payload);

    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req);
    } catch (e) {
      yield StreamEvent.error('$e');
      return;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = await resp.stream.bytesToString();
      yield StreamEvent.error('HTTP ${resp.statusCode}: $body');
      return;
    }

    final toolCalls = <int, _OpenAIToolCallAccumulator>{};
    String? finishReason;
    String currentContent = '';
    String currentReasoning = '';

    await for (final line in resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') {
        break;
      }
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;
        final delta = choice['delta'] as Map<String, dynamic>?;
        if (delta == null) continue;

        if (finishReason == null && choice['finish_reason'] is String) {
          finishReason = choice['finish_reason'] as String;
        }

        final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          currentReasoning += reasoning;
          yield StreamEvent(type: 'reasoning', thinkingDelta: reasoning);
        }

        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          currentContent += content;
          yield StreamEvent(type: 'content', contentDelta: content);
        }

        final tc = delta['tool_calls'];
        if (tc is List) {
          for (final raw in tc) {
            if (raw is! Map) continue;
            final map = raw;
            final index = (map['index'] as int?) ?? 0;
            final acc = toolCalls.putIfAbsent(index, () => _OpenAIToolCallAccumulator());
            if (map['id'] is String) acc.id = map['id'] as String;
            final fn = map['function'];
            if (fn is Map) {
              if (fn['name'] is String) acc.name = (fn['name'] as String);
              if (fn['arguments'] is String) {
                acc.arguments = (acc.arguments ?? '') + (fn['arguments'] as String);
              }
            }
          }
        }
      } catch (_) {
        // ignore malformed chunks
      }
    }

    // Handle tool calls if any
    if (toolCalls.isNotEmpty && onToolCall != null) {
      final assistantToolCalls = <Map<String, dynamic>>[];
      final toolMessages = <Map<String, dynamic>>[];
      for (final acc in toolCalls.values) {
        final name = acc.name ?? '';
        final args = acc.arguments ?? '';
        final id = acc.id ?? '';
        // Announce the tool call before executing so the UI can show
        // a "running" state immediately.
        yield StreamEvent.toolStart(id: id, name: name, arguments: args);
        Map<String, dynamic> argsJson;
        try {
          argsJson = (jsonDecode(args) as Map<String, dynamic>);
        } catch (_) {
          argsJson = {'raw': args};
        }
        assistantToolCalls.add({
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': args},
        });
        String toolResult;
        bool success = true;
        String? toolError;
        try {
          toolResult = await onToolCall({
            'id': id,
            'name': name,
            'arguments': argsJson,
          });
        } catch (e) {
          // The AI still needs to see the error so it can recover; we
          // also flag the failure so the UI can render it as failed.
          toolResult = 'Error: $e';
          success = false;
          toolError = e.toString();
        }
        yield StreamEvent.toolDone(
          id: id,
          name: name,
          result: toolResult,
          success: success,
          error: toolError,
        );
        toolMessages.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': toolResult,
        });
      }
      // Continue the conversation with tool result
      final followMessages = <ChatRequestMessage>[
        ...messages,
        ChatRequestMessage(
          role: MessageRole.assistant,
          content: currentContent,
          thinking: currentReasoning,
        ),
      ];
      final followupPayload = <String, dynamic>{
        'model': model,
        'stream': true,
        'messages': _buildOpenAIMessages(followMessages, systemPrompt),
        'tools': tools ?? const [],
      };
      // insert tool_calls into the assistant message for protocol compliance
      final msgs = followupPayload['messages'] as List;
      final lastAssistant = msgs.last as Map<String, dynamic>;
      lastAssistant['content'] = currentContent.isEmpty ? null : currentContent;
      lastAssistant['tool_calls'] = assistantToolCalls;
      msgs.addAll(toolMessages);

      final followupReq = http.Request('POST', Uri.parse(provider.fullChatUrl))
        ..headers.addAll(_openAIHeaders(provider))
        ..body = jsonEncode(followupPayload);
      final followupResp = await _client.send(followupReq);
      if (followupResp.statusCode < 200 || followupResp.statusCode >= 300) {
        final body = await followupResp.stream.bytesToString();
        yield StreamEvent.error('HTTP ${followupResp.statusCode}: $body');
        return;
      }
      await for (final line in followupResp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices.first as Map)['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;
          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            yield StreamEvent(type: 'content', contentDelta: content);
          }
        } catch (_) {}
      }
    }

    yield StreamEvent.done();
  }

  Stream<StreamEvent> _streamAnthropic({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
  }) async* {
    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'max_tokens': 4096,
      'messages': _buildAnthropicMessages(messages),
    };
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      payload['system'] = systemPrompt;
    }
    if (tools != null && tools.isNotEmpty) {
      payload['tools'] = tools;
    }

    final req = http.Request('POST', Uri.parse(provider.fullChatUrl))
      ..headers.addAll(_anthropicHeaders(provider))
      ..body = jsonEncode(payload);

    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req);
    } catch (e) {
      yield StreamEvent.error('$e');
      return;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = await resp.stream.bytesToString();
      yield StreamEvent.error('HTTP ${resp.statusCode}: $body');
      return;
    }

    final toolUseBlocks = <Map<String, dynamic>>[];
    String currentStopReason = '';

    await for (final line in resp.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final type = json['type'] as String?;
        switch (type) {
          case 'content_block_start':
            final block = json['content_block'] as Map<String, dynamic>?;
            if (block != null && block['type'] == 'tool_use') {
              toolUseBlocks.add({
                'id': block['id'],
                'name': block['name'],
                'input': '',
              });
            }
            break;
          case 'content_block_delta':
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta == null) break;
            final deltaType = delta['type'];
            if (deltaType == 'thinking_delta') {
              final text = delta['thinking'];
              if (text is String && text.isNotEmpty) {
                yield StreamEvent(type: 'reasoning', thinkingDelta: text);
              }
            } else if (deltaType == 'text_delta') {
              final text = delta['text'];
              if (text is String && text.isNotEmpty) {
                yield StreamEvent(type: 'content', contentDelta: text);
              }
            } else if (deltaType == 'input_json_delta') {
              if (toolUseBlocks.isNotEmpty) {
                final last = toolUseBlocks.last;
                last['input'] = (last['input'] as String) + (delta['partial_json'] as String? ?? '');
              }
            }
            break;
          case 'message_delta':
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['stop_reason'] is String) {
              currentStopReason = delta['stop_reason'] as String;
            }
            break;
        }
      } catch (_) {
        // ignore malformed chunks
      }
    }

    if (currentStopReason == 'tool_use' && toolUseBlocks.isNotEmpty && onToolCall != null) {
      final toolResults = <Map<String, dynamic>>[];
      for (final tb in toolUseBlocks) {
        final name = tb['name'] as String? ?? '';
        final id = tb['id'] as String? ?? '';
        final argsRaw = tb['input'] as String? ?? '';
        yield StreamEvent.toolStart(id: id, name: name, arguments: argsRaw);
        Map<String, dynamic> args;
        try {
          args = (jsonDecode(argsRaw) as Map<String, dynamic>);
        } catch (_) {
          args = {'raw': argsRaw};
        }
        String toolResult;
        bool success = true;
        String? toolError;
        try {
          toolResult = await onToolCall({
            'id': id,
            'name': name,
            'arguments': args,
          });
        } catch (e) {
          toolResult = 'Error: $e';
          success = false;
          toolError = e.toString();
        }
        yield StreamEvent.toolDone(
          id: id,
          name: name,
          result: toolResult,
          success: success,
          error: toolError,
        );
        toolResults.add({
          'type': 'tool_result',
          'tool_use_id': id,
          'content': toolResult,
        });
      }
      // Build follow-up request
      final followupMessages = <Map<String, dynamic>>[
        ..._buildAnthropicMessages(messages),
        {
          'role': 'assistant',
          'content': [
            for (final tb in toolUseBlocks)
              {
                'type': 'tool_use',
                'id': tb['id'],
                'name': tb['name'],
                'input': jsonDecode(tb['input'] as String? ?? '{}'),
              },
          ],
        },
        {'role': 'user', 'content': toolResults},
      ];

      final followupPayload = <String, dynamic>{
        'model': model,
        'stream': true,
        'max_tokens': 4096,
        'messages': followupMessages,
      };
      if (systemPrompt != null && systemPrompt.isNotEmpty) {
        followupPayload['system'] = systemPrompt;
      }
      if (tools != null && tools.isNotEmpty) {
        followupPayload['tools'] = tools;
      }

      final followupReq = http.Request('POST', Uri.parse(provider.fullChatUrl))
        ..headers.addAll(_anthropicHeaders(provider))
        ..body = jsonEncode(followupPayload);
      final followupResp = await _client.send(followupReq);
      if (followupResp.statusCode < 200 || followupResp.statusCode >= 300) {
        final body = await followupResp.stream.bytesToString();
        yield StreamEvent.error('HTTP ${followupResp.statusCode}: $body');
        return;
      }
      await for (final line in followupResp.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (line.isEmpty) continue;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final type = json['type'] as String?;
          if (type == 'content_block_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['type'] == 'text_delta') {
              final text = delta['text'];
              if (text is String && text.isNotEmpty) {
                yield StreamEvent(type: 'content', contentDelta: text);
              }
            }
          }
        } catch (_) {}
      }
    }

    yield StreamEvent.done();
  }

  List<Map<String, dynamic>> _buildOpenAIMessages(
      List<ChatRequestMessage> messages, String? systemPrompt) {
    final out = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      out.add({'role': 'system', 'content': systemPrompt});
    }
    for (final m in messages) {
      switch (m.role) {
        case MessageRole.user:
          if (m.imageDataUrls.isNotEmpty) {
            final parts = <Map<String, dynamic>>[];
            if (m.content.isNotEmpty) {
              parts.add({'type': 'text', 'text': m.content});
            }
            for (final url in m.imageDataUrls) {
              parts.add({
                'type': 'image_url',
                'image_url': {'url': url},
              });
            }
            out.add({'role': 'user', 'content': parts});
          } else {
            out.add({'role': 'user', 'content': m.content});
          }
          break;
        case MessageRole.assistant:
          out.add({'role': 'assistant', 'content': m.content});
          break;
        case MessageRole.system:
          out.add({'role': 'system', 'content': m.content});
          break;
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _buildAnthropicMessages(List<ChatRequestMessage> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      switch (m.role) {
        case MessageRole.user:
          if (m.imageDataUrls.isNotEmpty) {
            final parts = <Map<String, dynamic>>[];
            if (m.content.isNotEmpty) {
              parts.add({'type': 'text', 'text': m.content});
            }
            for (final url in m.imageDataUrls) {
              // OpenAI-style data URLs (`data:image/...;base64,...`)
              // round-trip into Anthropic's expected source object.
              final mediaType = _mediaTypeFromDataUrl(url);
              final data = _dataFromDataUrl(url);
              parts.add({
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': mediaType,
                  'data': data,
                },
              });
            }
            out.add({'role': 'user', 'content': parts});
          } else {
            out.add({'role': 'user', 'content': m.content});
          }
          break;
        case MessageRole.assistant:
          out.add({'role': 'assistant', 'content': m.content});
          break;
        case MessageRole.system:
          // Anthropic uses top-level system; caller should pass via systemPrompt.
          out.add({'role': 'user', 'content': m.content});
          break;
      }
    }
    return out;
  }

  String _mediaTypeFromDataUrl(String dataUrl) {
    final commaIdx = dataUrl.indexOf(',');
    if (dataUrl.startsWith('data:') && commaIdx > 5) {
      final meta = dataUrl.substring(5, commaIdx);
      final semi = meta.indexOf(';');
      if (semi > 0) return meta.substring(0, semi);
    }
    return 'image/jpeg';
  }

  String _dataFromDataUrl(String dataUrl) {
    final commaIdx = dataUrl.indexOf(',');
    if (commaIdx < 0) return dataUrl;
    return dataUrl.substring(commaIdx + 1);
  }
}

class _OpenAIToolCallAccumulator {
  String? id;
  String? name;
  String? arguments;
}
