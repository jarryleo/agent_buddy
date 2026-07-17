import 'calendar_service.dart' show PlatformPermissionStatus;
import 'voice_service.dart';

/// Test-only [VoiceService]. Every call throws so callers can assert
/// the real implementation (or a fake) is injected in tests. Mirror of
/// the other `*_stub.dart` files in this directory.
class VoiceServiceStub implements VoiceService {
  @override
  Future<PlatformPermissionStatus> ensurePermission() async =>
      PlatformPermissionStatus.notSupported;

  @override
  Future<PlatformPermissionStatus> requestPermission() async =>
      PlatformPermissionStatus.notSupported;

  @override
  Future<bool> get isAvailable async => false;

  @override
  bool get isListening => false;

  @override
  VoiceError get lastError => VoiceError.unavailable;

  @override
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    VoiceLevelCallback? onLevel,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 3),
  }) =>
      Future.value(false);

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> cancelListening() async {}
}
