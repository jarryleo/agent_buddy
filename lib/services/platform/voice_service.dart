import 'calendar_service.dart' show PlatformPermissionStatus;

/// Result of a speech recognition attempt.
class VoiceResult {
  const VoiceResult({required this.text, required this.finalResult});

  /// The (partial or final) recognized text.
  final String text;

  /// Whether this is the last result of the listening session.
  final bool finalResult;
}

/// Callbacks for a live voice-capture session. The UI wires these to
/// its own state (level meter, live transcript, error banners).
typedef VoiceLevelCallback = void Function(double level);
typedef VoiceResultCallback = void Function(VoiceResult result);
typedef VoiceStatusCallback = void Function(String status);

/// Why the most recent [VoiceService.startListening] failed, so the UI can
/// show a precise, actionable message (and, on a permanent denial, point
/// the user to system settings) instead of a generic "failed".
enum VoiceError {
  none,
  permissionDenied,
  permanentlyDenied,
  unavailable,
  unknown,
}

/// Cross-platform voice input. Wraps the `stts` plugin (which itself
/// delegates to `android.speech.SpeechRecognizer` on Android,
/// `SFSpeechRecognizer` on iOS / macOS, SAPI on Windows, and the
/// browser's `SpeechRecognition` API on web) so the rest of the app
/// never touches the plugin directly and can be unit-tested against a
/// stub.
///
/// ## Permission flow
///
/// On Android the microphone permission must be granted *before* the
/// recognizer can start. The `stts` plugin exposes a `hasPermission()`
/// helper but it only returns a boolean — it has no way to distinguish
/// "user just declined this prompt" from "user has permanently denied
/// and we should send them to system settings". The dedicated
/// [requestPermission] call wraps `permission_handler.microphone` so
/// the UI gets a precise `granted` / `denied` / `permanentlyDenied`
/// answer and can route the user to system settings when needed.
///
/// On iOS `stts` internally calls `SFSpeechRecognizer.requestAuthorization`
/// + `AVAudioSession.requestRecordPermission` from its `hasPermission()`
/// helper. We still gate on `permission_handler` first so the
/// permanently-denied case is reported correctly.
///
/// Web and desktop either don't gate on a runtime permission or use
/// their own browser-level flow — `requestPermission` short-circuits
/// to the underlying `stts.isSupported()` check on those platforms.
abstract class VoiceService {
  /// Best-effort pre-check of whether speech recognition is usable.
  /// Cheap; only inspects engine availability. Does NOT show any UI.
  /// Use [requestPermission] for the actual permission prompt.
  Future<PlatformPermissionStatus> ensurePermission();

  /// Show the system microphone permission dialog if the permission
  /// is not already granted. Returns the post-prompt status so the
  /// caller can show a precise message on a `denied` or route the
  /// user to system settings on a `permanentlyDenied`.
  ///
  /// This MUST be called before [startListening] on platforms that
  /// gate the speech engine on the mic permission (i.e. Android + iOS).
  Future<PlatformPermissionStatus> requestPermission();

  /// Whether the underlying speech engine is available on this device.
  Future<bool> get isAvailable;

  /// Whether a listening session is currently active.
  bool get isListening;

  /// The reason the last [startListening] call failed, or [VoiceError.none]
  /// if it succeeded / hasn't been attempted. Read this when
  /// [startListening] returns `false` to pick the right user message.
  VoiceError get lastError;

  /// Start a listening session. [onResult] fires for every partial and
  /// final transcript; [onStatus] reports the engine status string
  /// (synthesized by the wrapper as `'listening'` / `'notListening'` /
  /// `'done'` from stts's `SttState` stream so the UI code is unchanged
  /// from the previous `speech_to_text`-based implementation); [onLevel]
  /// is an optional 0..1 amplitude meter for a live waveform. Returns
  /// false if the session couldn't be started (e.g. permission denied,
  /// no engine).
  ///
  /// [listenFor] / [pauseFor] are accepted for backwards compatibility
  /// with the previous API but are NOT forwarded to the engine — `stts`
  /// does not expose them. The platform recognizer auto-ends after a
  /// short silence (~3s on Android / iOS, ~10s on Windows) and emits a
  /// final result before stopping. If the user is still long-pressing
  /// the chat-input mic when that happens, the wrapper auto-restarts
  /// the session (capped at a few restarts to prevent runaway loops)
  /// so the user can pause between thoughts and keep dictating without
  /// releasing and re-pressing the button.
  ///
  /// [localeId] picks the recognition language as a BCP-47 tag
  /// (e.g. `'zh-CN'`, `'en-US'`). `stts` matches against its platform
  /// recognizer's supported locale list; an unknown value falls back
  /// to the recognizer's default — which on Windows is the system
  /// locale and is frequently wrong for our users, so the caller should
  /// pass an explicit locale that matches the user's app language.
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    VoiceLevelCallback? onLevel,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
    String? localeId,
  });

  /// Stop the active listening session. The final transcript (if any)
  /// is delivered through the [onResult] registered in [startListening]
  /// with [VoiceResult.finalResult] == true.
  Future<void> stopListening();

  /// Cancel the active session and discard any in-progress transcript.
  /// On `stts` this is identical to [stopListening] (the plugin has no
  /// cancel primitive); the wrapper just clears the in-flight
  /// subscription state so trailing partials can't leak through.
  Future<void> cancelListening();
}

typedef VoiceServiceBuilder = VoiceService Function();
