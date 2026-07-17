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

/// Why the most recent [startListening] failed, so the UI can show a
/// precise, actionable message (and, on a permanent denial, point the
/// user to system settings) instead of a generic "failed".
enum VoiceError {
  none,
  permissionDenied,
  permanentlyDenied,
  unavailable,
  unknown,
}

/// Cross-platform voice input. Wraps `speech_to_text` so the rest of
/// the app never touches the plugin directly and can be unit-tested
/// against a stub.
///
/// ## Permission flow
///
/// On Android the microphone permission must be granted *before* the
/// `speech_to_text` engine can start. The plugin handles this itself
/// in [startListening], but the resulting OS dialog is unreliable on
/// some Android skins (MIUI / EMUI / ColorOS) and the plugin can
/// fail silently — surfacing only as a generic "couldn't start"
/// error in [lastError]. The dedicated [requestPermission] call wraps
/// `permission_handler` so the UI gets a precise
/// `granted` / `denied` / `permanentlyDenied` answer and can route
/// the user to system settings when needed.
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
  /// gate the speech engine on the mic permission (i.e. Android).
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
  /// (`listening`, `notListening`, `done`, …); [onLevel] is an optional
  /// 0..1 amplitude meter for a live waveform. Returns false if the
  /// session couldn't be started (e.g. permission denied, no engine).
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    VoiceLevelCallback? onLevel,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 3),
  });

  /// Stop the active listening session. The final transcript (if any)
  /// is delivered through the [onResult] registered in [startListening]
  /// with [VoiceResult.finalResult] == true.
  Future<void> stopListening();

  /// Cancel the active session and discard any in-progress transcript.
  Future<void> cancelListening();
}

typedef VoiceServiceBuilder = VoiceService Function();
