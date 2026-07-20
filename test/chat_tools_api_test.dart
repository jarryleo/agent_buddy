import 'dart:convert';

import 'package:agent_buddy/models/file_attachment.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  ModelProvider provider(ProviderProtocol protocol) {
    return ModelProvider(
      id: 'provider',
      name: 'Test',
      protocol: protocol,
      baseUrl: 'https://example.com',
      apiKey: 'key',
      chatPath: protocol.defaultPath,
    );
  }

  test(
    'OpenAI-compatible request sends text file metadata and Qwen thinking mode',
    () async {
      Map<String, dynamic>? payload;
      final api = ApiService(
        client: MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('data: [DONE]\n\n', 200);
        }),
      );

      await api
          .streamChat(
            provider: provider(ProviderProtocol.openai),
            model: 'qwen3-32b',
            enableThinking: true,
            messages: const [
              ChatRequestMessage(
                role: MessageRole.user,
                content: 'Summarize this file',
                fileAttachments: [
                  PreparedFileAttachment(
                    name: 'notes.txt',
                    path: '',
                    size: 5,
                    mimeType: 'text/plain',
                    textContent: 'hello',
                  ),
                ],
              ),
            ],
          )
          .toList();

      expect(payload!['enable_thinking'], isTrue);
      final messages = payload!['messages'] as List;
      final content = (messages.single as Map)['content'] as List;
      expect(
        content.whereType<Map>().any(
          (part) =>
              part['type'] == 'text' &&
              part['text'].toString().contains('notes.txt'),
        ),
        isTrue,
      );
    },
  );

  test('OpenAI GPT-5 request uses reasoning effort', () async {
    Map<String, dynamic>? payload;
    final api = ApiService(
      client: MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('data: [DONE]\n\n', 200);
      }),
    );

    await api
        .streamChat(
          provider: provider(ProviderProtocol.openai),
          model: 'gpt-5',
          enableThinking: true,
          messages: const [
            ChatRequestMessage(role: MessageRole.user, content: 'Hello'),
          ],
        )
        .toList();

    expect(payload!['reasoning_effort'], 'medium');
  });

  test('Anthropic request enables extended thinking', () async {
    Map<String, dynamic>? payload;
    final api = ApiService(
      client: MockClient((request) async {
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response('', 200);
      }),
    );

    await api
        .streamChat(
          provider: provider(ProviderProtocol.anthropic),
          model: 'claude-sonnet',
          enableThinking: true,
          messages: const [
            ChatRequestMessage(role: MessageRole.user, content: 'Hello'),
          ],
        )
        .toList();

    expect(payload!['thinking'], {'type': 'enabled', 'budget_tokens': 2048});
  });

  test('OpenAI rebuilds tools before each orchestrator round', () async {
    final payloads = <Map<String, dynamic>>[];
    var requestCount = 0;
    var buildCount = 0;
    var loaded = false;
    final api = ApiService(
      client: MockClient((request) async {
        payloads.add(jsonDecode(request.body) as Map<String, dynamic>);
        requestCount++;
        if (requestCount == 1) {
          final event = jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'load-call',
                      'function': {
                        'name': 'load_tool',
                        'arguments': '{"tool_names":["current_time"]}',
                      },
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          });
          return http.Response('data: $event\n\ndata: [DONE]\n\n', 200);
        }
        final event = jsonEncode({
          'choices': [
            {
              'delta': {'content': 'done'},
              'finish_reason': 'stop',
            },
          ],
        });
        return http.Response('data: $event\n\ndata: [DONE]\n\n', 200);
      }),
    );

    List<Map<String, dynamic>> buildTools() {
      buildCount++;
      return [
        _toolSchema('load_tool'),
        if (loaded) _toolSchema('current_time'),
      ];
    }

    final events = await api
        .streamChat(
          provider: provider(ProviderProtocol.openai),
          model: 'test-model',
          messages: const [
            ChatRequestMessage(role: MessageRole.user, content: 'What time?'),
          ],
          toolsBuilder: () async => buildTools(),
          onToolCall: (call) async {
            loaded = true;
            return '{"loaded":["current_time"]}';
          },
        )
        .toList();

    expect(payloads, hasLength(2));
    expect(buildCount, 2);
    expect(_openAiToolNames(payloads.first), {'load_tool'});
    expect(_openAiToolNames(payloads.last), {'load_tool', 'current_time'});
    expect(events.where((event) => event.type == 'toolDone'), hasLength(1));
    expect(events.where((event) => event.contentDelta == 'done'), hasLength(1));
  });

  test('Anthropic rebuilds tools before each orchestrator round', () async {
    final payloads = <Map<String, dynamic>>[];
    var requestCount = 0;
    var buildCount = 0;
    var loaded = false;
    final api = ApiService(
      client: MockClient((request) async {
        payloads.add(jsonDecode(request.body) as Map<String, dynamic>);
        requestCount++;
        if (requestCount == 1) {
          final start = jsonEncode({
            'type': 'content_block_start',
            'index': 0,
            'content_block': {
              'type': 'tool_use',
              'id': 'load-call',
              'name': 'load_tool',
              'input': {},
            },
          });
          final arguments = jsonEncode({
            'type': 'content_block_delta',
            'index': 0,
            'delta': {
              'type': 'input_json_delta',
              'partial_json': '{"tool_names":["current_time"]}',
            },
          });
          final stop = jsonEncode({
            'type': 'message_delta',
            'delta': {'stop_reason': 'tool_use'},
          });
          return http.Response(
            'data: $start\n\ndata: $arguments\n\ndata: $stop\n\n',
            200,
          );
        }
        final content = jsonEncode({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'done'},
        });
        final stop = jsonEncode({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
        });
        return http.Response('data: $content\n\ndata: $stop\n\n', 200);
      }),
    );

    List<Map<String, dynamic>> buildTools() {
      buildCount++;
      return [
        _toolSchema('load_tool'),
        if (loaded) _toolSchema('current_time'),
      ];
    }

    final events = await api
        .streamChat(
          provider: provider(ProviderProtocol.anthropic),
          model: 'claude-sonnet',
          messages: const [
            ChatRequestMessage(role: MessageRole.user, content: 'What time?'),
          ],
          toolsBuilder: () async => buildTools(),
          onToolCall: (call) async {
            loaded = true;
            return '{"loaded":["current_time"]}';
          },
        )
        .toList();

    expect(payloads, hasLength(2));
    expect(buildCount, 2);
    expect(_anthropicToolNames(payloads.first), {'load_tool'});
    expect(_anthropicToolNames(payloads.last), {'load_tool', 'current_time'});
    expect(events.where((event) => event.type == 'toolDone'), hasLength(1));
    expect(events.where((event) => event.contentDelta == 'done'), hasLength(1));
  });
}

Map<String, dynamic> _toolSchema(String name) {
  return {
    'type': 'function',
    'function': {
      'name': name,
      'description': name,
      'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
    },
  };
}

Set<String> _openAiToolNames(Map<String, dynamic> payload) {
  return (payload['tools'] as List)
      .map((raw) => (raw as Map)['function'] as Map)
      .map((function) => function['name'] as String)
      .toSet();
}

Set<String> _anthropicToolNames(Map<String, dynamic> payload) {
  return (payload['tools'] as List)
      .map((raw) => (raw as Map)['name'] as String)
      .toSet();
}
