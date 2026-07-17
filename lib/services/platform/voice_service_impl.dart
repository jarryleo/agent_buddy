import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

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

  /// Whether the underlying platform actually gates the speech
  /// engine on the microphone permission. iOS / Android do; web
  /// and desktop either don't gate on a runtime permission or use
  /// their own browser-level flow.
  bool get _platformUsesPermission =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<bool> _ensureInitialized() async {
    if (_initialized) return _engine.isAvailable;
    _initialized = await _engine.initialize(
      onError: _onError,
      debugLogging: false,
      finalTimeout: const Duration(seconds: 30),
    );
    return _engine.isAvailable;
  }

  void _onError(dynamic error) {
    _lastError = _errorToVoiceError(error);
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
    if (s.isPermanentlyDenied) return PlatformPermissionStatus.permanentlyDenied;
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
    Duration pauseFor = const Duration(seconds: 3),
  }) async {
    final available = await _ensureInitialized();
    if (!available) {
      _lastError = VoiceError.unavailable;
      return false;
    }
    _lastError = VoiceError.none;
    bool? started;
    try {
      started = await _engine.listen(
        onResult: (result) {
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
          cancelOnError: true,
          listenMode: stt.ListenMode.confirmation,
        ),
      );
    } catch (e) {
      // Any activation failure (HRESULT errors, platform exceptions)
      // must not crash the UI; treat it as "couldn't start".
      _lastError = VoiceError.unknown;
      return false;
    }
    // On some platforms (e.g. Windows without an enabled dictation
    // engine) `listen` returns `null` instead of `false` when it can't
    // start. Never propagate that `Null` to the caller — fold it into a
    // clean `false` so the UI can show the "unavailable" message.
    final ok = started == true;
    if (!ok && _lastError == VoiceError.none) {
      _lastError = VoiceError.unknown;
    }
    return ok;
  }

  @override
  Future<void> stopListening() async {
    if (_engine.isListening) await _engine.stop();
  }

  @override
  Future<void> cancelListening() async {
    if (_engine.isListening) await _engine.cancel();
  }
}
