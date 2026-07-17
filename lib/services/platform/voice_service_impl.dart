import 'dart:async';

import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import 'calendar_service.dart' show PlatformPermissionStatus;
import 'voice_service.dart';

/// Production [VoiceService] backed by the `speech_to_text` plugin,
/// which performs on-device speech recognition on every Flutter
/// platform and owns its own permission prompts internally.
class VoiceServiceImpl implements VoiceService {
  final stt.SpeechToText _engine;

  VoiceServiceImpl({stt.SpeechToText? engine})
    : _engine = engine ?? stt.SpeechToText();

  bool _initialized = false;
  VoiceError _lastError = VoiceError.none;

  /// The most recent [VoiceService.startListening.onStatus] callback
  /// the UI passed in. `speech_to_text` registers `onStatus` **once,
  /// globally** in [stt.SpeechToText.initialize]; per-call updates
  /// have to be threaded through this field so the new value
  /// supersedes the previous one for status forwarding.
  VoiceStatusCallback? _userStatusCallback;

  /// One-shot liveness probe used by [startListening] to decide
  /// whether a `listen()` call that reported `false` was actually a
  /// false alarm. Set right before `_engine.listen(...)` is awaited;
  /// cleared after the call returns (and on success/timeout/error).
  ///
  /// The Windows backend (`speech_to_text` > WinRT
  /// `SpeechRecognizer`) has a well-known race where `listen()`
  /// returns `false` while the OS recognizer is still spinning up.
  /// The recognizer eventually fires the same result / status /
  /// level callbacks it would have fired had `listen()` returned
  /// `true`. We use this [Completer] to give the engine a short
  /// grace window during which any callback proves the session is
  /// alive; if nothing fires we treat it as a real failure.
  Completer<bool>? _livenessProbe;

  /// Whether the underlying platform actually gates the speech
  /// engine on the microphone permission. iOS / Android do; web
  /// and desktop either don't gate on a runtime permission or use
  /// their own browser-level flow.
  bool get _platformUsesPermission =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether the engine's `listen()` return value is racy enough to
  /// merit the grace-window logic in [startListening].
  ///
  /// On Android `SpeechRecognizer` the recognizer's `startListening`
  /// is dispatched to the main looper via `handler.post { ... }`,
  /// while the plugin's Kotlin side already returned `true` /
  /// `false` synchronously to Dart. The recognizer then fires
  /// `onReadyForSpeech` / `onBeginningOfSpeech` / the first partial
  /// asynchronously; if those callbacks race against a `cancel()`
  /// from a previous failed session, the plugin can hand back a
  /// transient `false` even though the new session is alive. We
  /// also see the same race on the desktop targets (WinRT
  /// `SpeechRecognizer` on Windows, `AVSpeechRecognizer` on macOS,
  /// vosk on Linux). iOS / web are excluded because their
  /// `listen()` contracts are synchronous and authoritative.
  bool get _hasRacyListenReturn =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// How long we wait for a liveness callback before deciding the
  /// session really did fail to start. 1.5s covers the typical
  /// cold-start of:
  ///   * WinRT `SpeechRecognizer` on Windows
  ///   * Android `SpeechRecognizer` (which has to bind to the
  ///     platform speech service, post `startListening` to the
  ///     main looper, and then deliver `onReadyForSpeech` /
  ///     `onBeginningOfSpeech` back through the method channel)
  /// without making the user wait noticeably for an
  /// honest-failure snackbar.
  static const Duration _livenessGrace = Duration(milliseconds: 1500);

  Future<bool> _ensureInitialized() async {
    if (_initialized) return _engine.isAvailable;
    try {
      _initialized = await _engine.initialize(
        onError: _onError,
        onStatus: _onEngineStatus,
        debugLogging: false,
        finalTimeout: const Duration(seconds: 30),
      );
    } catch (e) {
      // The Android plugin raises a `PlatformException` from
      // `SpeechRecognizer.isRecognitionAvailable == false` (e.g.
      // emulators without Google Speech Services, AOSP-only ROMs).
      // Surface that as a precise "unavailable" so the UI can
      // route the user to a precise message instead of an
      // unhandled async error.
      _lastError = VoiceError.unavailable;
      _initialized = false;
      return false;
    }
    return _engine.isAvailable;
  }

  /// The status callback registered with the speech engine in
  /// [_ensureInitialized]. `speech_to_text` only exposes a single,
  /// engine-scoped `onStatus` — we forward it to whatever the most
  /// recent [startListening] caller asked for. The status string
  /// also counts as proof of liveness: if it arrives during the
  /// grace window after a `false` return from `listen()`, the
  /// session is alive.
  void _onEngineStatus(String status) {
    _noteLiveness();
    final cb = _userStatusCallback;
    if (cb != null) cb(status);
  }

  /// Called from the speech engine on error. We both remember the
  /// reason (so the UI can choose a precise message) and resolve
  /// any in-flight liveness probe as a failure.
  void _onError(dynamic error) {
    _lastError = _errorToVoiceError(error);
    _noteLiveness(asFailure: true);
  }

  void _noteLiveness({bool asFailure = false}) {
    final c = _livenessProbe;
    if (c == null) return;
    if (!c.isCompleted) c.complete(!asFailure);
    _livenessProbe = null;
  }

  static VoiceError _errorToVoiceError(dynamic error) {
    final code = (error?.errorMsg?.toString() ?? '').toLowerCase();
    if (code.contains('permission')) {
      return (error?.permanent ?? false)
          ? VoiceError.permanentlyDenied
          : VoiceError.permissionDenied;
    }
    if (code.contains('not available') ||
        code.contains('unavailable') ||
        code.contains('recognizer')) {
      return VoiceError.unavailable;
    }
    return VoiceError.unknown;
  }

  @override
  Future<PlatformPermissionStatus> ensurePermission() async {
    if (!_platformUsesPermission) {
      final available = await _ensureInitialized();
      if (!available) return PlatformPermissionStatus.notSupported;
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
      final available = await _ensureInitialized();
      if (!available) return PlatformPermissionStatus.notSupported;
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

  static PlatformPermissionStatus _mapPermissionStatus(ph.PermissionStatus s) {
    if (s.isGranted || s.isLimited) return PlatformPermissionStatus.granted;
    if (s.isPermanentlyDenied)
      return PlatformPermissionStatus.permanentlyDenied;
    if (s.isRestricted) return PlatformPermissionStatus.permanentlyDenied;
    return PlatformPermissionStatus.denied;
  }

  @override
  Future<bool> get isAvailable async => _ensureInitialized();

  @override
  bool get isListening => _engine.isListening;

  @override
  VoiceError get lastError => _lastError;

  @override
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    VoiceLevelCallback? onLevel,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
    String? localeId,
  }) async {
    final available = await _ensureInitialized();
    if (!available) {
      _lastError = VoiceError.unavailable;
      return false;
    }
    _lastError = VoiceError.none;

    // Stash the caller's status callback so the engine-global
    // `_onEngineStatus` can forward to it. Without this wiring the
    // UI never saw status updates and stayed stuck in
    // "session-not-actually-started" forever — that's the bug that
    // caused Windows users to see the "couldn't start" snackbar
    // even when recognition was actively working in the background.
    _userStatusCallback = onStatus;

    // Defensively clear any stale "listening" flag on the engine
    // before kicking off a new session.
    //
    // The Android `SpeechToText` plugin returns `false` from
    // `listen()` whenever its internal `listening` flag is still
    // `true` — which happens after:
    //   * a hot-reload during development (the Dart instance is
    //     recreated but the Kotlin plugin survives with
    //     `listening = true` from the previous session);
    //   * a previous recognizer that errored out without firing
    //     `onError` (rare on real devices, common on AOSP emulators
    //     without a working speech service — the mic indicator
    //     shows because `SpeechRecognizer.startListening()` is
    //     actively buffering audio, but no callbacks ever fire);
    //   * a quick re-press before the previous `stop()` /
    //     `cancel()` round-trip has reached the platform side.
    //
    // Cancel any in-flight session first so the new `listen()`
    // always gets a clean slate. `cancel()` is a no-op when the
    // recognizer isn't actually listening, so this is cheap on
    // the happy path.
    if (_engine.isListening) {
      try {
        await _engine.cancel();
      } catch (_) {
        // Worst case the cancel fails; `listen()` will still be
        // attempted and the grace-window below decides whether
        // to trust any callbacks that fire.
      }
    }

    final probe = _livenessProbe = Completer<bool>();

    bool? started;
    try {
      started = await _engine.listen(
        onResult: (result) {
          _noteLiveness();
          onResult(
            VoiceResult(
              text: result.recognizedWords,
              finalResult: result.finalResult,
            ),
          );
        },
        onSoundLevelChange: onLevel == null
            ? null
            : (levelDb) {
                _noteLiveness();
                // `speech_to_text` reports sound level in dB (≈ -80..0).
                // Normalize into a 0..1 meter for the waveform.
                const double minDb = -80.0;
                final clamped = levelDb.clamp(minDb, 0.0);
                onLevel((clamped - minDb) / -minDb);
              },
        listenOptions: stt.SpeechListenOptions(
          listenFor: listenFor,
          pauseFor: pauseFor,
          partialResults: true,
          // Don't tear down the session on a transient engine error
          // (e.g. WinRT's `error_speech_timeout` on a brief pause,
          // `error_no_match` on a soft utterance). Errors are still
          // reported via the `_onError` path so the UI can update
          // [lastError], but the recognizer keeps listening — which
          // is what we want for chat input where the user is
          // long-pressing the button.
          cancelOnError: false,
          // `dictation` is tuned for sentences / paragraphs; the
          // previous `confirmation` mode was optimised for short
          // command phrases and clipped the user mid-sentence on
          // WinRT (the engine's `pauseFor` countdown was tuned
          // aggressively for confirmation utterances). Dictation
          // mode gives the same WinRT backend a much more natural
          // model for chat input.
          listenMode: stt.ListenMode.dictation,
          localeId: localeId,
        ),
      );
    } catch (e) {
      _lastError = VoiceError.unknown;
      _livenessProbe = null;
      return false;
    }

    // listen() accepted. Engine is definitively up — clear the
    // probe (we don't need to wait further) and report success.
    if (started == true) {
      if (!probe.isCompleted) probe.complete(true);
      _livenessProbe = null;
      return true;
    }

    // An explicit engine error fired inside `listen()` or its
    // callback chain. Surface it directly — the engine is
    // authoritative, no grace window.
    if (_lastError != VoiceError.none) {
      return false;
    }

    // listen() returned `false` without throwing or erroring. On
    // platforms where the underlying speech backend is known to
    // race — WinRT `SpeechRecognizer` on Windows,
    // `AVSpeechRecognizer` on macOS, vosk on Linux, and Android's
    // `SpeechRecognizer` (whose `startListening` is dispatched via
    // `handler.post` and can race against a stale `listening`
    // flag from a previous session) — the engine frequently
    // returns a transient `false` even though the recognizer is
    // still spinning up. The result / status / level callbacks
    // WILL fire if/when it actually comes up. Give the engine a
    // short grace window during which any callback proves
    // liveness.
    if (!_hasRacyListenReturn) {
      _livenessProbe = null;
      _lastError = VoiceError.unknown;
      return false;
    }

    try {
      final gotCallback = await probe.future.timeout(
        _livenessGrace,
        onTimeout: () => false,
      );
      if (_lastError != VoiceError.none) return false;
      if (gotCallback) return true;
      // Grace window expired with no callback. Before declaring
      // failure, double-check the engine's own state — in rare
      // cases the recognizer comes up but no callback fires (e.g.
      // an empty session). If the engine says it's listening,
      // trust it.
      try {
        if (_engine.isListening) return true;
      } catch (_) {}
      _lastError = VoiceError.unknown;
      return false;
    } finally {
      _livenessProbe = null;
    }
  }

  @override
  Future<void> stopListening() async {
    _userStatusCallback = null;
    if (_engine.isListening) await _engine.stop();
  }

  @override
  Future<void> cancelListening() async {
    _userStatusCallback = null;
    if (_engine.isListening) await _engine.cancel();
  }
}
