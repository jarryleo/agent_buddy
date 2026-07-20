import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatProvider.computeRetryBackoff', () {
    // Locks in the user-facing schedule:
    //   attempt 1  →   5s  (first retry)
    //   attempt 2  →  10s
    //   attempt 3  →  20s
    //   attempt 4  →  40s
    //   attempt 5  →  80s
    //   attempt 6  → 160s
    //   attempt 7  → 320s  (cap)
    //   attempt 8  → 320s  (cap)
    //   …
    // attempt <= 0 is treated as "no retry yet" and returns 0
    // so the orchestrator can use computeRetryBackoff(attempt)
    // unconditionally.
    test('first attempt (0 or negative) is zero', () {
      expect(ChatProvider.computeRetryBackoff(0), Duration.zero);
      expect(ChatProvider.computeRetryBackoff(-1), Duration.zero);
      expect(ChatProvider.computeRetryBackoff(-100), Duration.zero);
    });

    test('doubles every step up to the 320s cap', () {
      const cases = <int, Duration>{
        1: Duration(seconds: 5),
        2: Duration(seconds: 10),
        3: Duration(seconds: 20),
        4: Duration(seconds: 40),
        5: Duration(seconds: 80),
        6: Duration(seconds: 160),
        7: Duration(seconds: 320),
      };
      cases.forEach((attempt, expected) {
        expect(
          ChatProvider.computeRetryBackoff(attempt),
          expected,
          reason: 'attempt $attempt should back off exactly $expected',
        );
      });
    });

    test('plateaus at 320s for attempts past the cap', () {
      for (var attempt = 8; attempt <= 30; attempt++) {
        expect(
          ChatProvider.computeRetryBackoff(attempt),
          const Duration(seconds: 320),
          reason: 'attempt $attempt should still be capped at 320s',
        );
      }
    });
  });

  group('ChatProvider.isRetryableNetworkError', () {
    test('classic ClientException from the bug report is retryable', () {
      // Verbatim error string from the user-reported flaky
      // provider session (OpenRouter in this case). The
      // classifier MUST return true so the orchestrator
      // triggers the backoff schedule.
      const err =
          'ClientException: Connection closed before full header was received, '
          'uri=https://openrouter.ai/api/v1/chat/completions';
      expect(ChatProvider.isRetryableNetworkError(err), isTrue);
    });

    test('empty string is not retryable (defensive guard)', () {
      expect(ChatProvider.isRetryableNetworkError(''), isFalse);
    });

    test('dart:io SocketException is retryable', () {
      const err =
          'SocketException: Connection refused (OS Error: Connection refused, '
          'errno = 111), address = 198.51.100.1, port = 443';
      expect(ChatProvider.isRetryableNetworkError(err), isTrue);
    });

    test('TimeoutException is retryable', () {
      const err = 'TimeoutException after 0:00:30.000000: Future not completed';
      expect(ChatProvider.isRetryableNetworkError(err), isTrue);
    });

    test('DNS resolution failure is retryable', () {
      const err =
          'SocketException: Failed host lookup: api.example.com '
          '(OS Error: No address associated with hostname, errno = 11)';
      expect(ChatProvider.isRetryableNetworkError(err), isTrue);
    });

    test('HTTP 5xx gateway errors are retryable', () {
      for (final code in const ['502', '503', '504', '524']) {
        final err = 'HTTP $code: Service Unavailable';
        expect(
          ChatProvider.isRetryableNetworkError(err),
          isTrue,
          reason: 'HTTP $code should be classified as transient',
        );
      }
    });

    test('HTTP 401 (auth) is NOT retryable', () {
      // Auth failures never recover by retrying on the same
      // credentials — surfacing them lets the user fix their
      // key in Settings.
      const err =
          'HTTP 401: {"error":{"message":"Invalid API key","type":"..."}}';
      expect(ChatProvider.isRetryableNetworkError(err), isFalse);
    });

    test('HTTP 400 (bad request) is NOT retryable', () {
      const err = 'HTTP 400: missing required field "messages"';
      expect(ChatProvider.isRetryableNetworkError(err), isFalse);
    });

    test('HTTP 500 is deliberately NOT retryable', () {
      // "500 Internal Server Error" can come from app bugs or
      // permanent schema mismatches. Retrying it forever would
      // burn CPU / pollute logs; the user wants visibility.
      const err = 'HTTP 500: Unexpected application error';
      expect(ChatProvider.isRetryableNetworkError(err), isFalse);
    });

    test('mixed-case error strings still match', () {
      // The classifier lowercases its input so a passing-through
      // HttpException (capital H) etc. still triggers retry.
      const err =
          'HTTPCLIENTEXCEPTION: CONNECTION CLOSED BEFORE FULL HEADER WAS RECEIVED';
      expect(ChatProvider.isRetryableNetworkError(err), isTrue);
    });

    test('unrelated server response is NOT retryable', () {
      const err =
          'HTTP 200: {"error":"Slow response but ultimately succeeded"}';
      expect(ChatProvider.isRetryableNetworkError(err), isFalse);
    });
  });
}
