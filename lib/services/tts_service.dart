import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:stts/stts.dart';

/// Cross-platform text-to-speech. Wraps `stts`'s `Tts` class (which
/// itself delegates to the platform-native voice — Android's
/// `TextToSpeech`, iOS / macOS `AVSpeechSynthesizer`, Windows SAPI,
/// web's `SpeechSynthesis` API) so the rest of the app never touches
/// the plugin directly and can be unit-tested against a fake.
///
/// ## Single active speaker
///
/// At most one bubble is allowed to be speaking at a time —
/// [speakingMessageId] is the single source of truth. Tapping the
/// speaker button on a *different* bubble mid-playback causes the
/// engine to stop + restart on the new text; tapping the *same*
/// bubble mid-playback stops the engine and returns to idle. This
/// mirrors what users expect from a chat-app read-aloud: one
/// paragraph at a time, no overlaps.
///
/// The notifier is a [ValueListenable] (rather than a more
/// elaborate [ChangeNotifier] / Provider publish) so bubbles can
/// scope their subscription to just this one knob — they only
/// need to rebuild when *this* bubble's id matches / un-matches
/// the speaking id, and they don't need the rest of the tree to
/// rebuild along with them.
class TtsService {
  /// Optional engine injection for tests. Defaults to a fresh `Tts`.
  final Tts _engine;

  TtsService({Tts? engine}) : _engine = engine ?? Tts();

  static const TtsOptions _ttsOptions = TtsOptions(
    preSilence: Duration.zero,
    postSilence: Duration.zero,
  );

  /// Backing store for [isSupported] / [isSupportedNotifier].
  bool _supported = false;

  /// Whether the first [Tts.isSupported] call has resolved.
  /// `_supported` is *only* meaningful once this is `true`.
  bool _supportChecked = false;

  /// Reactive flag the bubble binds to so the speaker icon can
  /// pop into view the moment the engine probe lands. Starts
  /// `false` (we don't know yet); flips to the engine's answer
  /// after the first [initialize] call.
  ///
  /// Exposed as a [ValueListenable] rather than a
  /// [ChangeNotifier] on the service itself — the bubble only
  /// needs to rebuild when *this* knob flips, not when any of
  /// the other state changes. A dedicated notifier scopes the
  /// subscription to just this flag.
  final ValueNotifier<bool> isSupportedNotifier = ValueNotifier<bool>(false);

  /// Whether the underlying engine reports it can produce speech
  /// on this device. Becomes `true` after the first [initialize]
  /// call once the engine responds. Bubbles gate the speaker
  /// button's visibility on this getter.
  bool get isSupported => isSupportedNotifier.value;

  /// The id of the message currently being spoken (matches
  /// `ChatMessage.id` from the bubble that owns it), or `null`
  /// when no speech is active. Listened to by each bubble's
  /// `_MessageBubbleState` so it can flip its icon between
  /// `volume_up` and `stop`.
  final ValueNotifier<String?> speakingMessageId = ValueNotifier<String?>(null);

  /// True when the engine is paused (not stopped). The bubble
  /// uses this to swap its icon to "play" when the user pressed
  /// pause and back to "stop" when speech resumes. Mirrors stts's
  /// `TtsState.pause` event.
  final ValueNotifier<bool> isPausedNotifier = ValueNotifier<bool>(false);

  /// True when a `speak()` call is in flight or the engine is
  /// actively producing audio. Stays true between `TtsState.start`
  /// and the next `TtsState.stop`. (The `stop` may be triggered
  /// by the engine itself at the end of an utterance, or by our
  /// own `stop()` from a tap or a swap to another bubble.)
  bool get isSpeaking => speakingMessageId.value != null;

  StreamSubscription<TtsState>? _stateSub;
  bool _disposed = false;

  /// One-shot lazy init: probes [Tts.isSupported] and wires the
  /// state stream listener. Safe to call multiple times — only
  /// the first call does real work.
  ///
  /// Called eagerly from `main.dart` at app startup so the bubble
  /// knows whether to show the speaker button *before* its first
  /// render. Without this eager probe, the bubble would always
  /// start with `isSupportedNotifier.value == false` (the default)
  /// and stay button-less forever — there's no other event that
  /// triggers `initialize()`, so the user would see no speaker
  /// UI even on platforms where the engine is fully wired up.
  Future<void> initialize() async {
    if (_supportChecked || _disposed) return;
    try {
      _supported = await _engine.isSupported();
    } catch (_) {
      // Some platforms (notably web in some browsers) throw rather
      // than returning `false`. Treat any exception as "not
      // supported" so the bubble can hide its button.
      _supported = false;
    }
    _supportChecked = true;
    // Flip the notifier *only if* the value actually changed —
    // avoids spurious rebuilds on re-init.
    if (isSupportedNotifier.value != _supported) {
      isSupportedNotifier.value = _supported;
    }
    if (_supported && _stateSub == null) {
      _stateSub = _engine.onStateChanged.listen(_onEngineState);
    }
  }

  /// Forward the engine's state stream into the notifiers the
  /// bubble binds to. Three states:
  ///   * `start`  — engine is producing audio. Clear the paused
  ///                flag (a `resume()` after `pause()` also fires
  ///                `start` per `stts`'s convention).
  ///   * `pause`  — engine paused. Flip the paused flag.
  ///   * `stop`   — engine ended (either by us, by the user, or
  ///                naturally when the utterance finishes). Clear
  ///                both flags and drop the speaking id so the
  ///                bubble flips back to its idle icon.
  void _onEngineState(TtsState state) {
    switch (state) {
      case TtsState.start:
        if (isPausedNotifier.value) {
          isPausedNotifier.value = false;
        }
      case TtsState.pause:
        if (!isPausedNotifier.value) {
          isPausedNotifier.value = true;
        }
      case TtsState.stop:
        _clearSpeakingState();
    }
  }

  void _clearSpeakingState() {
    if (isPausedNotifier.value) isPausedNotifier.value = false;
    if (speakingMessageId.value != null) {
      speakingMessageId.value = null;
    }
  }

  static String _prepareText(String text) {
    if (defaultTargetPlatform != TargetPlatform.windows) return text;
    var prepared = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
    prepared = prepared.replaceAll(
      RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]'),
      '',
    );
    return prepared;
  }

  /// Speak [text] aloud, attributing it to the bubble with id
  /// [messageId]. Calling on a different bubble mid-playback
  /// stops the in-flight utterance and restarts on the new text;
  /// calling on the same bubble mid-playback toggles playback
  /// off. The `localeId` is a BCP-47 tag (e.g. `'zh-CN'`,
  /// `'en-US'`) — `null` means "let the engine pick its current
  /// default voice".
  ///
  /// Quietly no-ops when:
  ///   * [text] is empty or whitespace-only — nothing to say.
  ///   * the engine reports it's not supported (e.g. Linux /
  ///     no-TTS-installed). The bubble is expected to have hidden
  ///     its button via [isSupported] by this point.
  Future<void> speak(String messageId, String text, {String? localeId}) async {
    if (_disposed) return;
    if (text.trim().isEmpty) return;
    await initialize();
    if (!_supported) return;

    // Tapped the same bubble → toggle off. `stop()` will fire
    // `TtsState.stop` on its own and clear `speakingMessageId`.
    if (speakingMessageId.value == messageId) {
      await _stopEngine();
      return;
    }

    // Tapped a different bubble → swap. Stop in-flight, drop the
    // old id, then start on the new text. We `await stop()` first
    // so the new `start()` doesn't race the previous `stop()` in
    // the engine's internal queue.
    if (speakingMessageId.value != null) {
      await _stopEngine();
    }

    if (localeId != null && localeId.isNotEmpty) {
      try {
        await _engine.setLanguage(localeId);
      } catch (_) {
        // Best-effort; the engine still speaks in its current
        // voice if the requested locale isn't installed.
      }
    }

    final preparedText = _prepareText(text);
    if (preparedText.trim().isEmpty) return;
    speakingMessageId.value = messageId;
    if (isPausedNotifier.value) isPausedNotifier.value = false;

    try {
      final options = defaultTargetPlatform == TargetPlatform.windows
          ? _ttsOptions
          : const TtsOptions();
      await _engine.start(preparedText, options: options);
    } catch (_) {
      if (speakingMessageId.value == messageId) {
        _clearSpeakingState();
      }
    }
  }

  /// Stop the engine right now. A no-op when no message is
  /// currently being spoken. The state subscription clears
  /// [speakingMessageId] and the pause flag once `TtsState.stop`
  /// propagates.
  Future<void> stop() async {
    if (_disposed) return;
    if (speakingMessageId.value == null) return;
    await _stopEngine();
  }

  /// Pause the engine. The bubble's icon flips to "resume"; a
  /// subsequent [speak] (same id) becomes a resume instead of a
  /// restart. No-op when the engine is paused or not speaking.
  Future<void> pause() async {
    if (_disposed) return;
    if (speakingMessageId.value == null) return;
    if (isPausedNotifier.value) return;
    try {
      await _engine.pause();
    } catch (_) {
      // Some platforms don't support pause (e.g. web's
      // `SpeechSynthesis.pause()` is unreliable across browsers);
      // swallow the error and leave the state unchanged.
    }
  }

  /// Resume after [pause]. No-op when the engine is not paused.
  Future<void> resume() async {
    if (_disposed) return;
    if (speakingMessageId.value == null) return;
    if (!isPausedNotifier.value) return;
    try {
      await _engine.resume();
    } catch (_) {
      // Best-effort; the engine might just keep speaking.
    }
  }

  Future<void> _stopEngine() async {
    try {
      await _engine.stop();
    } catch (_) {}
    _clearSpeakingState();
  }

  /// Tear-down. Cancels the state subscription and disposes the
  /// underlying engine. Called from `main.dart` on app shutdown
  /// (typically never — the app process lives until the OS kills
  /// it), but kept for completeness and for tests that construct a
  /// transient instance.
  Future<void> dispose() async {
    _disposed = true;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _engine.dispose();
    } catch (_) {
      // Disposing twice (or after the engine already shut down)
      // is safe on most platforms but throws on others — ignore.
    }
    speakingMessageId.dispose();
    isPausedNotifier.dispose();
    isSupportedNotifier.dispose();
  }
}
