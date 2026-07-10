/// Pure-Dart policy class that decides whether a chat list
/// should auto-scroll to the bottom. Extracted from
/// `home_page.dart` so the rules are unit-testable without
/// spinning up the whole widget tree.
///
/// Rules:
///   1. **Force** (the user just sent a message): the next
///      auto-scroll runs unconditionally, even if the user had
///      scrolled up. This is what the user expects when they
///      tap "send".
///   2. **Stream** (AI is replying): we only auto-scroll if the
///      user was already parked at the bottom. If they had
///      scrolled up to read history we leave them alone.
///   3. **Coalesce**: multiple calls in the same frame collapse
///      into a single jump.
///   4. **Skip when already at bottom**: if the live scroll
///      position is within 1 pixel of the new max scroll
///      extent, there's nothing to do.
///
/// The class is a small state machine; it's intentionally
/// framework-agnostic (no `BuildContext`, no `ScrollController`)
/// so it can be exercised in pure-Dart unit tests.
class AutoScrollPolicy {
  bool _userAtBottom = true;
  bool _forceNext = false;
  bool _scheduled = false;

  /// True when the user is currently parked at (or very near)
  /// the bottom of the list. Driven externally via
  /// [markUserAtBottom] / [markUserNotAtBottom] when the
  /// scroll controller emits change events.
  bool get userAtBottom => _userAtBottom;

  /// True while a post-frame jump has been queued but not yet
  /// fired. Mainly useful for tests.
  bool get isScheduled => _scheduled;

  /// Mark the user as parked at the bottom. Called by the
  /// scroll-controller listener when the position is within
  /// [_bottomSlop] of `maxScrollExtent`.
  void markUserAtBottom() {
    _userAtBottom = true;
  }

  /// Mark the user as having scrolled away from the bottom.
  void markUserNotAtBottom() {
    _userAtBottom = false;
  }

  /// Reset the policy to its initial "fresh conversation"
  /// state — used when switching to a new session.
  void reset() {
    _userAtBottom = true;
    _forceNext = false;
    _scheduled = false;
  }

  /// Public hook for the chat input. The user just submitted a
  /// message; the next auto-scroll MUST land at the bottom even
  /// if the user was reading older history. Call this from the
  /// send path so the very next frame's post-frame jump runs
  /// unconditionally.
  void requestForceScrollToBottom() {
    _forceNext = true;
  }

  /// Returns the result of [schedule] given a snapshot of the
  /// current scroll position. `pixels` and `maxScrollExtent`
  /// are read at call time (typically inside the post-frame
  /// callback, after layout). Returns:
  ///   - `null` if no jump should happen.
  ///   - a number if a jump should happen, the desired target
  ///     pixels (which is `maxScrollExtent` in practice).
  ///
  /// This is the **decision**; the caller is responsible for
  /// actually calling `controller.jumpTo(target)`.
  double? schedule({
    required double pixels,
    required double maxScrollExtent,
    double bottomSlop = 32,
  }) {
    if (_scheduled) return null;
    final force = _forceNext;
    _forceNext = false;
    if (!force && !_userAtBottom) return null;
    _scheduled = true;
    // The actual jump is gated by the live position vs the
    // (newly laid-out) max. This is the only check the
    // post-frame callback can rely on — `_userAtBottom` is a
    // sticky flag updated by the listener when the *previous*
    // jump settled, so by the time we get here the new content
    // has already shifted `maxScrollExtent` past the old
    // `pixels`. The classic "pixels < max - slop" check would
    // therefore bail out incorrectly when AI is streaming
    // (we just jumped, then more content arrives, then we
    // check pixels at the *old* max against the *new* max).
    final atBottom = maxScrollExtent <= pixels + 1;
    if (atBottom) {
      // Nothing to do — release the schedule so the next
      // frame can still trigger a jump if more content arrives.
      _scheduled = false;
      return null;
    }
    if (!force && !_userAtBottom) {
      _scheduled = false;
      return null;
    }
    return maxScrollExtent;
  }

  /// Called by the post-frame callback after it actually runs
  /// the jump. Resets the scheduled flag so the next frame
  /// can queue another jump if needed.
  void markJumped() {
    _scheduled = false;
  }
}
