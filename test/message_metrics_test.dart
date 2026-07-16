import 'package:agent_buddy/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('estimateTokens', () {
    test('returns 0 for empty input', () {
      expect(estimateTokens(''), 0);
    });

    test('counts CJK characters roughly one-per-token', () {
      // 4 Chinese characters → 4 tokens under the heuristic.
      expect(estimateTokens('你好世界'), 4);
    });

    test('counts ASCII text roughly 4 chars per token', () {
      // 12 ASCII chars → 12 / 4 = 3 tokens (round up).
      expect(estimateTokens('hello world!'), 3);
    });

    test('mixes CJK and ASCII buckets independently', () {
      // "你好 hello" → 2 CJK tokens + (6 ascii + 3) ~/ 4 = 2 + 2 = 4.
      expect(estimateTokens('你好 hello'), 4);
    });

    test('counts multi-byte (non-CJK) characters as ~2 bytes per token', () {
      // é is 0xE9 (single multi-byte code-unit in UTF-16) → 1 token.
      // accented Latin is grouped with the `other` bucket at 2 per token.
      expect(estimateTokens('é'), 1);
    });
  });

  group('MessageMetrics.ttft', () {
    test('is null before the first token arrives', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(turnStartedAt: t);
      expect(m.ttft, isNull);
    });

    test('is the delta from turnStartedAt to firstTokenAt', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 500)),
      );
      expect(m.ttft, const Duration(milliseconds: 500));
    });
  });

  group('MessageMetrics.decodeDuration', () {
    test('is null before the first token arrives', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(turnStartedAt: t);
      expect(m.decodeDuration, isNull);
    });

    test('is null after the first token until the second arrives', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 500)),
      );
      expect(m.decodeDuration, isNull);
    });

    test('is the delta from firstTokenAt to lastTokenAt', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 500)),
        lastTokenAt: t.add(const Duration(seconds: 3, milliseconds: 500)),
      );
      expect(m.decodeDuration, const Duration(seconds: 3));
    });

    test('clamps to zero when timestamps are out of order', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(seconds: 2)),
        lastTokenAt: t.add(const Duration(seconds: 1)),
      );
      expect(m.decodeDuration, Duration.zero);
    });
  });

  group('MessageMetrics.tokensPerSecond', () {
    test('is null without a decode window', () {
      final t = DateTime(2026, 1, 1, 10);
      expect(MessageMetrics(turnStartedAt: t).tokensPerSecond, isNull);
    });

    test('is null when zero tokens were emitted', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 100)),
        lastTokenAt: t.add(const Duration(seconds: 2)),
        outputTokens: 0,
      );
      expect(m.tokensPerSecond, isNull);
    });

    test('divides output tokens by the decode duration in seconds', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 500)),
        lastTokenAt: t.add(const Duration(milliseconds: 2500)),
        outputTokens: 50,
      );
      // 2 seconds window, 50 tokens → 25 tps.
      expect(m.tokensPerSecond, 25.0);
    });

    test('handles sub-second decode windows without dividing by zero', () {
      final t = DateTime(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t,
        lastTokenAt: t.add(const Duration(microseconds: 1)),
        outputTokens: 5,
      );
      expect(m.tokensPerSecond, isNotNull);
      expect(m.tokensPerSecond, greaterThan(0));
    });
  });

  group('MessageMetrics JSON round-trip', () {
    test('round-trips a fully-populated metrics record', () {
      final t = DateTime.utc(2026, 1, 1, 10);
      final m = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 250)),
        lastTokenAt: t.add(const Duration(seconds: 5)),
        outputTokens: 240,
        inputTokens: 1024,
      );
      final json = m.toJson();
      final round = MessageMetrics.fromJson(json);
      expect(round.turnStartedAt, m.turnStartedAt);
      expect(round.firstTokenAt, m.firstTokenAt);
      expect(round.lastTokenAt, m.lastTokenAt);
      expect(round.outputTokens, 240);
      expect(round.inputTokens, 1024);
    });

    test('fromJson defaults unset optional timestamps to null', () {
      final round = MessageMetrics.fromJson({
        'turnStartedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
        'outputTokens': 100,
        'inputTokens': 200,
      });
      expect(round.firstTokenAt, isNull);
      expect(round.lastTokenAt, isNull);
      expect(round.outputTokens, 100);
      expect(round.inputTokens, 200);
    });

    test('fromJson defaults missing fields without throwing', () {
      // Worst-case legacy record: only the turnStartedAt anchor
      // is set. Mirrors what an interrupted stream might write.
      final round = MessageMetrics.fromJson({
        'turnStartedAt': DateTime.utc(2026, 1, 1).toIso8601String(),
      });
      expect(round.firstTokenAt, isNull);
      expect(round.lastTokenAt, isNull);
      expect(round.outputTokens, 0);
      expect(round.inputTokens, 0);
      expect(round.ttft, isNull);
    });

    test('fromJson falls back to now() for a corrupt turnStartedAt', () {
      // A record corrupted by manual edits shouldn't crash the
      // bubble — we substitute `now()` so the timestamp still
      // renders. TTFT will be 0 but the chip will silently omit
      // itself because `firstTokenAt` is null.
      final round = MessageMetrics.fromJson({'turnStartedAt': 'not-a-date'});
      expect(
        round.turnStartedAt.isBefore(
          DateTime.now().add(const Duration(seconds: 2)),
        ),
        isTrue,
      );
      expect(round.firstTokenAt, isNull);
    });
  });

  group('ChatMessage.metrics integration', () {
    test('defaults to null on construction', () {
      final m = ChatMessage(id: 'm', role: MessageRole.assistant);
      expect(m.metrics, isNull);
    });

    test('round-trips through ChatMessage JSON', () {
      final t = DateTime.utc(2026, 1, 1, 10);
      final m = ChatMessage(
        id: 'a',
        role: MessageRole.assistant,
        content: 'hi',
        metrics: MessageMetrics(
          turnStartedAt: t,
          firstTokenAt: t.add(const Duration(milliseconds: 100)),
          outputTokens: 1,
          inputTokens: 4,
        ),
      );
      final round = ChatMessage.fromJson(m.toJson());
      expect(round.metrics, isNotNull);
      expect(round.metrics!.outputTokens, 1);
      expect(round.metrics!.inputTokens, 4);
      expect(round.metrics!.ttft, const Duration(milliseconds: 100));
    });

    test('omits the metrics key from JSON when null', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      expect(m.toJson().containsKey('metrics'), isFalse);
    });

    test('legacy v1 records without metrics decode to null', () {
      final legacy = <String, dynamic>{
        'id': 'legacy',
        'role': 'assistant',
        'content': 'old reply',
        'thinking': '',
        'createdAt': DateTime.now().toIso8601String(),
        'toolCalls': <dynamic>[],
        'imagePaths': <dynamic>[],
      };
      final m = ChatMessage.fromJson(legacy);
      expect(m.metrics, isNull);
    });

    test('copyWith can attach metrics after the fact', () {
      final t = DateTime.utc(2026, 1, 1, 10);
      final m = ChatMessage(id: 'm', role: MessageRole.assistant);
      final metrics = MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: t.add(const Duration(milliseconds: 250)),
      );
      final round = m.copyWith(metrics: metrics);
      expect(round.metrics, isNotNull);
      expect(round.metrics!.ttft, const Duration(milliseconds: 250));
    });
  });
}
