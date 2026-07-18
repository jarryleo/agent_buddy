import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/services.dart' show PlatformException;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:stts/stts.dart';

import 'calendar_service.dart' show PlatformPermissionStatus;
import 'voice_service.dart';

/// Production [VoiceService] backed by the `stts` plugin, which
/// wraps the platform-native recognizer
/// (`android.speech.SpeechRecognizer` on Android,
/// `SFSpeechRecognizer` on iOS / macOS, SAPI on Windows, and the
/// browser's `SpeechRecognition` API on web). The wrapper adds three
/// things on top of the bare plugin:
///
///   1. A reliable, `permission_handler`-backed permission prompt
///      that can distinguish "user declined once" from "user has
///      permanently denied and we should send them to system
///      settings" — `stts.hasPermission()` only returns a boolean.
///   2. A liveness probe: `stts.start()` returns `Future<void>` and
///      succeeds immediately even if the OS recognizer is still
///      spinning up. We wait up to 1.5s for the corresponding
///      `SttState.start` event (Android: `onReadyForSpeech`, iOS:
///      `audioEngine.start()`, Windows: SAPI callback). Any error
///      that fires inside the grace window is treated as a real
///      failure; otherwise we trust the engine.
///   3. Synthetic lifecycle events. `stts` only exposes two
///      states (`start` / `stop`); the previous `speech_to_text`
///      contract surfaced `listening` / `notListening` / `done` and
///      the chat-input UI is wired to those exact strings. We
///      translate at the boundary so the rest of the app doesn't
///      notice the swap.
class VoiceServiceImpl implements VoiceService {
  /// Optional engine injection for tests. Defaults to a fresh [Stt].
  final Stt _engine;

  VoiceServiceImpl({Stt? engine}) : _engine = engine ?? Stt();

  /// Set by [_startListening] when the platform is known to support
  /// speech recognition. Independent of the user's mic permission —
  /// see [_requestPermissionOrError] for the auth-gated check.
  bool _supported = false;
  bool _supportChecked = false;
  VoiceError _lastError = VoiceError.none;

  /// The most recent [VoiceService.startListening.onStatus] callback
  /// the UI passed in. `stts` delivers state via a single, engine-
  /// scoped stream; per-call updates are threaded through this field
  /// so the new value supersedes the previous one for forwarding.
  VoiceStatusCallback? _userStatusCallback;

  /// One-shot liveness probe used by [_startListening] to decide
  /// whether the recognizer actually came up. Set right before
  /// `_engine.start(...)` is awaited; cleared after the call
  /// returns (and on success/timeout/error).
  ///
  /// On every platform `stts.start()` returns immediately while the
  /// OS recognizer is still spinning up (Android's `SpeechRecognizer`
  /// is dispatched to the main looper via `handler.post`, Windows'
  /// SAPI recognizer has a cold-start, iOS's `audioEngine.start()`
  /// has to bring up the audio session). We give the recognizer a
  /// short grace window during which any `SttState.start` event
  /// proves the session is alive; if nothing fires we treat it as
  /// a real failure.
  Completer<bool>? _livenessProbe;

  /// Stream subscriptions for the active session. Held so
  /// [stopListening] / [cancelListening] can tear them down cleanly
  /// and trailing partials / status events from a previous session
  /// don't leak into the next one.
  StreamSubscription<SttState>? _stateSub;
  StreamSubscription<SttRecognition>? _resultSub;

  /// True once the engine reports it's listening. Reset on
  /// `SttState.stop`. The chat-input UI uses this to distinguish a
  /// real recording session from a long-press whose pointer was
  /// released before the recognizer came up.
  bool _listening = false;

  /// How long we wait for a liveness callback before deciding the
  /// session really did fail to start. 1.5s covers the typical
  /// cold-start of:
  ///   * Android `SpeechRecognizer` (which has to bind to the
  ///     platform speech service, post `startListening` to the
  ///     main looper, and then deliver `onReadyForSpeech` back
  ///     through the event channel).
  ///   * iOS `SFSpeechRecognizer` (which has to bring up the audio
  ///     session via `AVAudioSession.setActive`).
  ///   * Windows SAPI (which has to load its inproc COM object on
  ///     first use).
  /// without making the user wait noticeably for an
  /// honest-failure snackbar.
  static const Duration _livenessGrace = Duration(milliseconds: 1500);

  /// Whether the underlying platform actually gates the speech
  /// engine on the microphone permission. Android / iOS do; web
  /// and desktop either don't gate on a runtime permission or use
  /// their own browser-level flow.
  bool get _platformUsesPermission =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<bool> _ensureSupported() async {
    if (_supportChecked) return _supported;
    try {
      _supported = await _engine.isSupported();
    } catch (_) {
      // The plugin throws (rather than returning `false`) on some
      // platforms when the underlying service is unreachable. Treat
      // any exception as "not supported".
      _supported = false;
    }
    _supportChecked = true;
    return _supported;
  }

  /// The status callback registered with the engine's state stream.
  /// We translate `stts`'s two-state enum into the `speech_to_text`-
  /// style strings the UI was wired against — the chat input listens
  /// for `'listening'` / `'notListening'` / `'done'` exactly.
  void _onEngineState(SttState state) {
    switch (state) {
      case SttState.start:
        _listening = true;
        _noteLiveness();
        _emitStatus('listening');
      case SttState.stop:
        _listening = false;
        _emitStatus('notListening');
    }
  }

  /// Called from the engine's event channel on error. We both
  /// remember the reason (so the UI can choose a precise message)
  /// and resolve any in-flight liveness probe as a failure.
  ///
  /// The shape of the error follows stts's convention: it is a
  /// `PlatformException` whose `code` is the integer SpeechRecognizer
  /// error code (Android) / SFSpeechRecognizer error string
  /// (iOS / macOS) / HRESULT (Windows). On Android the integer
  /// maps to the `SpeechRecognizer.ERROR_*` constants; we map those
  /// back to a human-readable tag (`permission`, `recognizer_busy`,
  /// …) via [_classifyError].
  void _onEngineError(Object error) {
    _lastError = _classifyError(error);
    _noteLiveness(asFailure: true);
    // Errors that aren't `permission` / `unavailable` still mean
    // the session is over on stts's side. Surface a generic
    // 'notListening' status so the chat-input UI clears its
    // listening state if the user is still holding the button.
    if (_lastError != VoiceError.permissionDenied &&
        _lastError != VoiceError.permanentlyDenied &&
        _lastError != VoiceError.unavailable) {
      _listening = false;
      _emitStatus('notListening');
    }
  }

  void _noteLiveness({bool asFailure = false}) {
    final c = _livenessProbe;
    if (c == null) return;
    if (!c.isCompleted) c.complete(!asFailure);
    _livenessProbe = null;
  }

  static VoiceError _classifyError(Object error) {
    // stts surfaces Android `SpeechRecognizer` errors as
    // `PlatformException(code: "<int>", message: "<tag>", details: null)`
    // — see android/.../SttStateStreamHandler.kt. The integer code is
    // the `SpeechRecognizer.ERROR_*` constant; the message is one of
    // the human-readable tags we see in the source:
    //   network_timeout, network, audio_error, server, client,
    //   speech_timeout, no_match, recognizer_busy, permission,
    //   too_many_requests, server_disconnected, language_not_supported,
    //   language_unavailable, cannot_check_support,
    //   cannot_listen_to_download_events, unknown.
    //
    // On iOS / macOS / Windows errors are surfaced as the native
    // error code as a string ("recognition_failed", "engine_busy",
    // etc.). We pattern-match on both the code and the message so a
    // new error string won't silently slip through as "unknown".
    final code =
        (error is PlatformException
                ? error.code
                : (error as dynamic)?.code?.toString())
            ?.toString()
            .toLowerCase() ??
        '';
    final message =
        (error is PlatformException
                ? error.message
                : (error as dynamic)?.message?.toString())
            ?.toString()
            .toLowerCase() ??
        '';
    final bag = '$code $message';
    if (bag.contains('permission') || bag.contains('9')) {
      // stts can't tell us "permanently" vs "once"; the
      // caller (requestPermission) is responsible for distinguishing
      // the two via permission_handler before we get here. Default
      // to the "still recoverable" bucket.
      return VoiceError.permissionDenied;
    }
    if (bag.contains('recognizer_busy') ||
        bag.contains('recognizer') ||
        bag.contains('unavailable') ||
        bag.contains('language') ||
        bag.contains('cannot')) {
      return VoiceError.unavailable;
    }
    return VoiceError.unknown;
  }

  static PlatformPermissionStatus _mapPermissionStatus(ph.PermissionStatus s) {
    if (s.isGranted || s.isLimited) return PlatformPermissionStatus.granted;
    if (s.isPermanentlyDenied)
      return PlatformPermissionStatus.permanentlyDenied;
    if (s.isRestricted) return PlatformPermissionStatus.permanentlyDenied;
    return PlatformPermissionStatus.denied;
  }

  void _emitStatus(String status) {
    final cb = _userStatusCallback;
    if (cb != null) cb(status);
  }

  /// Wire up the state / result streams just before we call
  /// [_engine.start]. The stream listeners:
  ///   * forward `start` / `stop` events to [VoiceStatusCallback]
  ///     ('listening' / 'notListening' / 'done');
  ///   * forward partial + final results to [VoiceResultCallback];
  ///   * classify errors and resolve the [_livenessProbe] on failure.
  ///
  /// The subscriptions are stored on the instance so [stopListening] /
  /// [cancelListening] can tear them down — otherwise trailing
  /// partials from a previous session would leak into the next one.
  void _attachStreams({
    required VoiceResultCallback onResult,
    required VoiceStatusCallback? onStatus,
  }) {
    // Reset prior session subscriptions before installing fresh ones.
    _stateSub?.cancel();
    _resultSub?.cancel();
    _userStatusCallback = onStatus;
    _stateSub = _engine.onStateChanged.listen(
      _onEngineState,
      onError: _onEngineError,
    );
    _resultSub = _engine.onResultChanged.listen((rec) {
      onResult(VoiceResult(text: rec.text, finalResult: rec.isFinal));
    }, onError: _onEngineError);
  }

  @override
  Future<PlatformPermissionStatus> ensurePermission() async {
    if (!_platformUsesPermission) {
      final supported = await _ensureSupported();
      if (!supported) return PlatformPermissionStatus.notSupported;
      return PlatformPermissionStatus.granted;
    }
    // Cheap sync status read — no UI side effects.
    final status = await ph.Permission.microphone.status;
    return _mapPermissionStatus(status);
  }

  @override
  Future<PlatformPermissionStatus> requestPermission() async {
    if (!_platformUsesPermission) {
      // Web / desktop: trust that the engine being available is
      // enough; the OS / browser handles its own mic UX. Initialize
      // eagerly so any failure surfaces here instead of as a
      // surprise in startListening.
      final supported = await _ensureSupported();
      if (!supported) return PlatformPermissionStatus.notSupported;
      return PlatformPermissionStatus.granted;
    }
    // First, if the user has *permanently* denied, don't pop the
    // dialog again (it would no-op on Android) — return the state
    // so the UI can offer the "open system settings" affordance.
    final current = await ph.Permission.microphone.status;
    if (current.isPermanentlyDenied) {
      return PlatformPermissionStatus.permanentlyDenied;
    }
    // Normal request path: shows the OS dialog. `request()` returns
    // the new (post-prompt) status, which is exactly what we want to
    // report back to the caller.
    final next = await ph.Permission.microphone.request();
    return _mapPermissionStatus(next);
  }

  @override
  Future<bool> get isAvailable async => _ensureSupported();

  @override
  bool get isListening => _listening;

  @override
  VoiceError get lastError => _lastError;

  @override
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
    String? localeId,
    VoiceLevelCallback? onLevel,
  }) async {
    final supported = await _ensureSupported();
    if (!supported) {
      _lastError = VoiceError.unavailable;
      return false;
    }
    _lastError = VoiceError.none;

    // Apply the locale *before* starting so the platform recognizer
    // picks the right model. `stts.setLanguage` is a no-op for
    // locales the recognizer doesn't support — it doesn't error.
    if (localeId != null && localeId.isNotEmpty) {
      try {
        await _engine.setLanguage(localeId);
      } catch (_) {
        // Best-effort; fall through to whatever the recognizer's
        // default is.
      }
    }

    _attachStreams(onResult: onResult, onStatus: onStatus);

    final probe = _livenessProbe = Completer<bool>();

    try {
      // `stts.start()` is fire-and-forget — it returns immediately
      // while the OS recognizer is still spinning up. The
      // `_onEngineState` callback we registered above will resolve
      // the liveness probe once `SttState.start` fires (Android:
      // `onReadyForSpeech`, iOS: `audioEngine.start()`, Windows:
      // SAPI callback).
      await _engine.start(
        const SttRecognitionOptions(
          // Offline-first; falls back to online on platforms that
          // don't support on-device recognition.
          offline: true,
          // Better punctuation / formatting where the platform
          // supports it (Android 13+, iOS 16+, macOS 13+).
          punctuation: true,
          ios: SttRecognitionIosOptions(
            taskHint: SttRecognitionDarwinTaskHint.dictation,
          ),
        ),
      );
    } catch (e) {
      _lastError = VoiceError.unknown;
      _livenessProbe = null;
      _teardownStreams();
      return false;
    }

    // Wait up to [_livenessGrace] for the recognizer to report
    // it's actually listening. Any error that fires inside the
    // grace window is treated as a real failure.
    final liveness = await probe.future.timeout(
      _livenessGrace,
      onTimeout: () => false,
    );

    if (_lastError != VoiceError.none) {
      _teardownStreams();
      return false;
    }
    if (liveness) return true;

    // Grace window expired with no callback. Trust the engine's
    // own state — in rare cases the recognizer comes up but the
    // state event is lost (e.g. an empty session). If the engine
    // says it's listening, trust it.
    if (_listening) return true;
    _lastError = VoiceError.unknown;
    _teardownStreams();
    return false;
  }

  @override
  Future<void> stopListening() async {
    _userStatusCallback = null;
    try {
      await _engine.stop();
    } catch (_) {
      // Best-effort — even if the native side rejects the stop,
      // we've torn down our stream subscriptions below.
    }
    _listening = false;
    _teardownStreams();
  }

  @override
  Future<void> cancelListening() async {
    // `stts` has no separate cancel primitive — `stop()` discards
    // the partial transcript, which is exactly what "cancel" means
    // from the caller's point of view.
    await stopListening();
  }

  void _teardownStreams() {
    _stateSub?.cancel();
    _stateSub = null;
    _resultSub?.cancel();
    _resultSub = null;
    _livenessProbe = null;
  }
}
