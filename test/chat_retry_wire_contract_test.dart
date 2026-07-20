import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  ModelProvider provider() {
    return ModelProvider(
      id: 'provider',
      name: 'Test',
      protocol: ProviderProtocol.openai,
      baseUrl: 'https://example.com',
      apiKey: 'key',
      chatPath: '/v1/chat/completions',
    );
  }

  group('ApiService surfaces network errors that the retry classifier '
      'recognizes', () {
    test('ClientException from the underlying transport flows through as '
        'an `error` event with the retryable substring intact', () async {
      // The chat retry loop classifies errors by substring match
      // against the `error` event's `text` field. If the
      // protocol layer ever rewrote a ClientException into a
      // different shape (e.g. replaced it with HTTP 502), the
      // retry chain would never start. This test guards the
      // wire contract: the verbatim ClientException toString
      // — which the user reported in the bug — must reach the
      // chat provider's listener unchanged.
      final api = ApiService(
        client: MockClient((request) async {
          throw http.ClientException(
            'Connection closed before full header was received',
            request.url,
          );
        }),
      );

      final events = await api
          .streamChat(
            provider: provider(),
            model: 'any',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'hi'),
            ],
          )
          .toList();

      final errors = events.where((e) => e.type == 'error').toList();
      expect(errors, hasLength(1));

      final errorText = errors.single.error ?? '';
      expect(
        errorText,
        contains('ClientException'),
        reason:
            'subclass prefix must be preserved so the retry '
            'classifier can match it',
      );
      expect(
        errorText,
        contains('Connection closed before full header was received'),
        reason: 'verbatim message text must be preserved',
      );
    });

    test('HTTP 4xx errors still surface (non-retryable hard errors)', () async {
      final api = ApiService(
        client: MockClient((request) async {
          return http.Response(
            '{"error":{"message":"Invalid API key"}}',
            401,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final events = await api
          .streamChat(
            provider: provider(),
            model: 'any',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'hi'),
            ],
          )
          .toList();

      final errors = events.where((e) => e.type == 'error').toList();
      expect(errors, hasLength(1));
      expect(errors.single.error, contains('HTTP 401'));
      // The classifier must NOT match this — see
      // chat_retry_backoff_test for that contract.
      expect(errors.single.error, isNot(contains('closed')));
    });
  });
}
