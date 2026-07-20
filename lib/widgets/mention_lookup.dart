/// Pure helpers that drive the chat-input `@` mention popup.
///
/// Kept separate from [ChatInput] so they can be unit-tested
/// without standing up a full widget tree (the matcher is the
/// single non-trivial bit of logic in the feature).
library;

/// Result of [_findMentionToken] when the user's cursor sits
/// inside an `@<query>` token. Carries the absolute offset of
/// the `@` so the caller can splice the resolved filename back
/// into the input box.
class MentionToken {
  const MentionToken({required this.atSign});
  final int atSign;
}

/// Locate the `@<query>` token the user's [caret] is sitting
/// inside, or `null` if the cursor isn't inside one.
///
/// Rules (matching the chat-app convention):
///   * the `@` must be at index 0 OR immediately preceded by
///     whitespace (so `user@example.com` doesn't trigger);
///   * there must be no whitespace, newline, or another `@`
///     between the `@` and the caret (so `@foo bar` only
///     matches `@foo`, not `@foo bar`).
///   * the caret itself must be at or after the `@`.
MentionToken? findMentionToken(String text, int caret) {
  if (caret <= 0) return null;
  final max = caret.clamp(0, text.length);
  for (int i = max - 1; i >= 0; i--) {
    final cu = text.codeUnitAt(i);
    if (cu == 0x40 /* '@' */ ) {
      final prevOk = i == 0 || _isMentionBoundary(text.codeUnitAt(i - 1));
      if (!prevOk) return null;
      // The whole token is `[i, caret)`; reject if anything in
      // that span looks like an unclosed mention (whitespace
      // would imply the user already finished typing the
      // candidate and moved on).
      for (int j = i + 1; j < caret; j++) {
        final cu2 = text.codeUnitAt(j);
        if (cu2 == 0x20 || cu2 == 0x0A || cu2 == 0x0D || cu2 == 0x09) {
          return null;
        }
      }
      return MentionToken(atSign: i);
    }
    // Stop walking once we hit whitespace / newline — the
    // current "word" can't span across whitespace, so any
    // earlier `@` is in a different token.
    if (cu == 0x20 || cu == 0x0A || cu == 0x0D || cu == 0x09) {
      return null;
    }
  }
  return null;
}

bool _isMentionBoundary(int cu) {
  return cu == 0x20 || cu == 0x0A || cu == 0x0D || cu == 0x09;
}

/// Score a filename against a lowercase query. Returns 0 for
/// non-matches so the caller can filter easily. Tiers:
///   * exact basename match → 1.0
///   * prefix match → 0.9
///   * substring (case-insensitive) → 0.7
double matchScore(String lowerName, String lowerQuery) {
  if (lowerName == lowerQuery) return 1.0;
  if (lowerName.startsWith(lowerQuery)) return 0.9;
  if (lowerName.contains(lowerQuery)) return 0.7;
  return 0.0;
}
