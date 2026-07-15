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
    'OpenAI-compatible request sends text files and Qwen thinking mode',
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
              part['text'].toString().contains('hello'),
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
}
