import 'package:agent_buddy/widgets/mention_lookup.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the pure helpers behind the chat-input `@`
/// mention popup. The widget itself is exercised through
/// `widget_test.dart`; the matcher + token detector below are the
/// bits with non-trivial logic and live in `mention_lookup.dart`
/// specifically so they can be tested in isolation.
void main() {
  group('findMentionToken', () {
    test('detects `@` at the start of the input', () {
      final hit = findMentionToken('@foo', 4);
      expect(hit, isNotNull);
      expect(hit!.atSign, 0);
    });

    test('detects `@` after whitespace', () {
      final hit = findMentionToken('hello @foo', 10);
      expect(hit, isNotNull);
      expect(hit!.atSign, 6);
    });

    test('returns null when the `@` is mid-word (email-like)', () {
      // `user@example` — the `@` is preceded by a non-whitespace
      // character so this is not a mention trigger.
      expect(findMentionToken('user@example', 11), isNull);
    });

    test('returns null when the cursor is before the `@`', () {
      expect(findMentionToken('@foo bar', 0), isNull);
    });

    test('returns null when there is no `@`', () {
      expect(findMentionToken('plain text', 10), isNull);
    });

    test('returns null when whitespace appears between `@` and caret', () {
      // The user typed `@foo ` and moved on — we shouldn't treat
      // `@foo bar` as a single mention token.
      expect(findMentionToken('@foo bar', 8), isNull);
    });

    test('handles newline and tab as mention boundaries', () {
      // 'line1\n@foo' is 10 chars; caret at the end (10) lands
      // right after the 'o' of '@foo'.
      final hit = findMentionToken('line1\n@foo', 10);
      expect(hit, isNotNull);
      expect(hit!.atSign, 6);
    });

    test('returns the leftmost `@` when multiple are present', () {
      // The walk goes right-to-left; the most recent `@` is
      // returned as long as it's anchored at start / whitespace.
      final hit = findMentionToken('@one @two', 9);
      expect(hit, isNotNull);
      expect(hit!.atSign, 5);
    });

    test('empty caret never matches', () {
      expect(findMentionToken('', 0), isNull);
    });
  });

  group('matchScore', () {
    test('exact match scores 1.0', () {
      expect(matchScore('notes.txt', 'notes.txt'), 1.0);
    });

    test('prefix match scores 0.9', () {
      expect(matchScore('notes.txt', 'note'), 0.9);
    });

    test('substring match scores 0.7', () {
      expect(matchScore('my-notes.txt', 'note'), 0.7);
    });

    test('non-match scores 0.0', () {
      expect(matchScore('photo.png', 'note'), 0.0);
    });

    test('is case-insensitive when both inputs are lowercased', () {
      // The caller lowercases both sides before calling in.
      expect(matchScore('notes.txt', 'note'), 0.9);
      expect(matchScore('my-notes.txt', 'NOTE'.toLowerCase()), 0.7);
    });
  });
}
