import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  ModelProvider provider() => ModelProvider(
        id: 'provider',
        name: 'Test',
        protocol: ProviderProtocol.openai,
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'key',
        chatPath: '/chat/completions',
      );

  test('orchestrator path: ClientException reaches the chat UI as an error '
      'event with the verbatim string (so the retry classifier fires)',
      () async {
    final api = ApiService(
      client: MockClient((request) async {
        throw http.ClientException(
          'Connection closed before full header was received',
          request.url,
        );
      }),
    );

    // onToolCall is non-null → exercises the ToolOrchestrator path
    // (the real production path used by ChatProvider).
    final events = await api
        .streamChat(
          provider: provider(),
          model: 'any',
          messages: const [
            ChatRequestMessage(role: MessageRole.user, content: 'hi'),
          ],
          onToolCall: (_) async => '{}',
        )
        .toList();

    final errors = events.where((e) => e.type == 'error').toList();
    expect(errors, hasLength(1),
        reason: 'the ClientException must surface exactly once as an error');
    final errorText = errors.single.error ?? '';
    expect(errorText, contains('ClientException'),
        reason: 'class prefix preserved for the retry classifier');
    expect(errorText, contains('Connection closed before full header'),
        reason: 'verbatim message preserved');
  });
}
