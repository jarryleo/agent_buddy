import 'package:agent_buddy/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage.retryAttempt / nextRetryAt', () {
    test('defaults are zero / null', () {
      final m = ChatMessage(id: 'm', role: MessageRole.assistant);
      expect(m.retryAttempt, 0);
      expect(m.nextRetryAt, isNull);
      expect(m.isRetrying, isFalse);
    });

    test('isRetrying requires both retryAttempt>0 AND a non-null '
        'nextRetryAt', () {
      // The getter mirrors `_setRetryStateOnMessage`'s atomic
      // write — when retryAttempt is bumped, nextRetryAt is
      // always set in the same copyWith call, so the two
      // can't realistically disagree. The tests below just
      // lock in that contract: any combination where either
      // is missing reads as not-retrying, so a partial
      // clearNextRetryAt cleanup can't accidentally leave the
      // banner showing.
      final base = ChatMessage(id: 'm', role: MessageRole.assistant);
      expect(base.isRetrying, isFalse);

      // retryAttempt with no nextRetryAt → not retrying.
      final attemptOnly = base.copyWith(
        retryAttempt: 3,
        clearNextRetryAt: true,
      );
      expect(attemptOnly.isRetrying, isFalse);

      // nextRetryAt with no retryAttempt → not retrying
      // (the user cleared retryAttempt but the timestamp
      // was left over from before clearNextRetryAt kicked
      // in — defensive guard).
      final timeOnly = base.copyWith(
        retryAttempt: 0,
        nextRetryAt: DateTime(2030),
      );
      expect(timeOnly.isRetrying, isFalse);

      // Both set → retrying.
      final future = DateTime.now().add(const Duration(seconds: 10));
      final live = base.copyWith(retryAttempt: 1, nextRetryAt: future);
      expect(live.isRetrying, isTrue);
    });

    test('JSON omits the retry fields entirely (session-only state)', () {
      // Auto-retry state is intentionally NOT persisted — it
      // would resurface a stale countdown on next launch after
      // a transient network blip. The JSON round-trip should
      // always carry `retryAttempt: 0` and `nextRetryAt: null`
      // regardless of what the in-memory object holds.
      final live = ChatMessage(
        id: 'm',
        role: MessageRole.assistant,
        retryAttempt: 4,
        nextRetryAt: DateTime(2030),
      );
      final json = live.toJson();
      expect(json.containsKey('retryAttempt'), isFalse);
      expect(json.containsKey('nextRetryAt'), isFalse);

      final round = ChatMessage.fromJson(json);
      expect(round.retryAttempt, 0);
      expect(round.nextRetryAt, isNull);
      expect(round.isRetrying, isFalse);
    });

    test('copyWith can set retryAttempt + nextRetryAt', () {
      final base = ChatMessage(id: 'm', role: MessageRole.assistant);
      final nextAt = DateTime.now().add(const Duration(seconds: 5));
      final next = base.copyWith(retryAttempt: 1, nextRetryAt: nextAt);
      expect(next.retryAttempt, 1);
      expect(next.nextRetryAt, nextAt);
    });

    test('clearNextRetryAt flag wipes nextRetryAt without touching '
        'retryAttempt', () {
      // The orchestrator's _clearRetryStateOnMessage() needs to
      // drop the nextRetryAt timestamp while keeping the
      // retryAttempt wherever it is (it'll be overwritten right
      // after to 0 anyway, but the explicit flag keeps the
      // intent obvious in the call site).
      final scheduled = ChatMessage(
        id: 'm',
        role: MessageRole.assistant,
        retryAttempt: 3,
        nextRetryAt: DateTime(2030),
      );
      final cleared = scheduled.copyWith(clearNextRetryAt: true);
      expect(cleared.retryAttempt, 3);
      expect(cleared.nextRetryAt, isNull);
    });

    test('copyWith(nextRetryAt:null) without flag does NOT clear', () {
      // Sanity guard: copyWith's regular "?? this.field"
      // semantics mean passing null explicitly should NOT
      // overwrite an existing nextRetryAt with null. The flag
      // is the only way to clear, which keeps future
      // refactors from accidentally wiping the countdown.
      final scheduled = ChatMessage(
        id: 'm',
        role: MessageRole.assistant,
        retryAttempt: 2,
        nextRetryAt: DateTime(2030),
      );
      // Need to opt-in to clearing via the flag.
      final unchanged = scheduled.copyWith();
      expect(unchanged.nextRetryAt, scheduled.nextRetryAt);
      expect(unchanged.retryAttempt, 2);
    });
  });
}
