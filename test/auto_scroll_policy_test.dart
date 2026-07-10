import 'package:agent_buddy/pages/auto_scroll_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AutoScrollPolicy', () {
    test('initial state: user is at bottom, schedule is a no-op when '
        'already at max', () {
      final p = AutoScrollPolicy();
      // pixels == maxScrollExtent: already at the bottom.
      expect(p.schedule(pixels: 1000, maxScrollExtent: 1000), isNull);
      // pixels within 1 pixel of max: still considered "at the
      // bottom" and skipped.
      expect(p.schedule(pixels: 1000.5, maxScrollExtent: 1000), isNull);
    });

    test('stream-scroll: jumps while user is at the bottom', () {
      final p = AutoScrollPolicy();
      // First call: AI streams content, max grew. The user was
      // already at the bottom (default state).
      final target1 = p.schedule(pixels: 800, maxScrollExtent: 1000);
      expect(target1, 1000);
      // markJumped() resets the scheduled flag.
      p.markJumped();
      // Next stream tick: more content arrived, max grew again,
      // but our `pixels` is still at the previous max. The
      // naive check `pixels < max - 32` would have bailed
      // out here, which is exactly the bug we fixed.
      final target2 = p.schedule(pixels: 1000, maxScrollExtent: 1500);
      expect(target2, 1500);
      p.markJumped();
    });

    test('stream-scroll: does not jump if user scrolled up', () {
      final p = AutoScrollPolicy();
      // User scrolls up to read history.
      p.markUserNotAtBottom();
      // AI streams new content. The user is no longer at the
      // bottom; we must NOT yank the scroll.
      final target = p.schedule(pixels: 200, maxScrollExtent: 1500);
      expect(target, isNull);
    });

    test('stream-scroll: resumes jumping when user scrolls back to '
        'the bottom', () {
      final p = AutoScrollPolicy();
      p.markUserNotAtBottom();
      // ... time passes, AI streams (no jumps) ...
      expect(p.schedule(pixels: 200, maxScrollExtent: 1500), isNull);
      // User scrolls back to the bottom.
      p.markUserAtBottom();
      // Next stream tick: we jump again.
      expect(p.schedule(pixels: 1500, maxScrollExtent: 1700), 1700);
    });

    test('force-scroll: jumps even if user is not at the bottom', () {
      final p = AutoScrollPolicy();
      // User is reading history.
      p.markUserNotAtBottom();
      // User taps "send". The flag forces the next jump.
      p.requestForceScrollToBottom();
      final target = p.schedule(pixels: 200, maxScrollExtent: 1500);
      expect(target, 1500);
    });

    test('force-scroll: is one-shot', () {
      final p = AutoScrollPolicy();
      p.markUserNotAtBottom();
      p.requestForceScrollToBottom();
      // The next schedule() consumes the force flag.
      expect(p.schedule(pixels: 200, maxScrollExtent: 1500), 1500);
      // Subsequent schedule() calls fall back to the normal
      // "user at bottom" check — and the user is NOT at the
      // bottom, so we don't jump.
      expect(p.schedule(pixels: 1500, maxScrollExtent: 2000), isNull);
    });

    test('coalesce: multiple schedule calls in the same frame '
        'produce only one jump', () {
      final p = AutoScrollPolicy();
      // Three ticks in the same frame before any post-frame
      // callback fires. Only the first should return a target;
      // the rest return null (because isScheduled is true).
      final t1 = p.schedule(pixels: 800, maxScrollExtent: 1000);
      final t2 = p.schedule(pixels: 850, maxScrollExtent: 1050);
      final t3 = p.schedule(pixels: 900, maxScrollExtent: 1100);
      expect(t1, 1000);
      expect(t2, isNull);
      expect(t3, isNull);
    });

    test('reset clears all flags', () {
      final p = AutoScrollPolicy();
      p.requestForceScrollToBottom();
      p.markUserNotAtBottom();
      p.reset();
      // After reset, the policy is in its "fresh conversation"
      // state: user at bottom, no force, no scheduled.
      expect(p.userAtBottom, isTrue);
      // Force was consumed by reset; sending + streaming should
      // both be skipped because there's no fresh content to
      // jump to (pixels == max).
      expect(p.schedule(pixels: 0, maxScrollExtent: 0), isNull);
    });
  });
}
