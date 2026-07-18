import 'package:agent_buddy/services/platform/calendar_service.dart'
    show PlatformPermissionStatus;
import 'package:agent_buddy/services/platform/voice_service.dart';
import 'package:agent_buddy/services/platform/voice_service_factory.dart';
import 'package:agent_buddy/services/platform/voice_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// A controllable fake of [VoiceService] used to assert the permission
/// and listening state machine without touching the microphone.
class FakeVoiceService implements VoiceService {
  FakeVoiceService({
    this.permission = PlatformPermissionStatus.granted,
    this.available = true,
    this.errorOnFail = VoiceError.unknown,
  });

  final PlatformPermissionStatus permission;
  final bool available;
  final VoiceError errorOnFail;

  var ensurePermissionCalls = 0;
  var requestPermissionCalls = 0;
  var startListeningCalls = 0;
  var stopListeningCalls = 0;
  var cancelListeningCalls = 0;
  var listening = false;
  String? lastLocaleId;
  @override
  VoiceError lastError = VoiceError.none;

  @override
  Future<PlatformPermissionStatus> ensurePermission() async {
    ensurePermissionCalls++;
    return permission;
  }

  @override
  Future<PlatformPermissionStatus> requestPermission() async {
    requestPermissionCalls++;
    return permission;
  }

  @override
  Future<bool> get isAvailable async => available;

  @override
  bool get isListening => listening;

  @override
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    VoiceLevelCallback? onLevel,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 5),
    String? localeId,
  }) async {
    if (!available || permission == PlatformPermissionStatus.denied) {
      lastError = errorOnFail;
      return false;
    }
    startListeningCalls++;
    lastLocaleId = localeId;
    listening = true;
    lastError = VoiceError.none;
    return true;
  }

  @override
  Future<void> stopListening() async {
    stopListeningCalls++;
    listening = false;
  }

  @override
  Future<void> cancelListening() async {
    cancelListeningCalls++;
    listening = false;
  }
}

void main() {
  group('VoiceService abstraction', () {
    test('stub reports notSupported + not available', () async {
      final svc = VoiceServiceStub();
      expect(
        await svc.ensurePermission(),
        PlatformPermissionStatus.notSupported,
      );
      expect(await svc.isAvailable, isFalse);
      expect(svc.isListening, isFalse);
      expect(await svc.startListening(onResult: (_) {}), isFalse);
    });

    test('factory returns the production implementation', () {
      // Just exercises the factory so it doesn't throw / regress.
      final svc = createVoiceService();
      expect(svc, isA<VoiceService>());
    });

    test('permission granted lets a session start', () async {
      final svc = FakeVoiceService();
      expect(await svc.ensurePermission(), PlatformPermissionStatus.granted);
      final started = await svc.startListening(
        onResult: (_) {},
        onLevel: (_) {},
      );
      expect(started, isTrue);
      expect(svc.isListening, isTrue);
      await svc.stopListening();
      expect(svc.isListening, isFalse);
      expect(svc.stopListeningCalls, 1);
    });

    test('permission denied surfaces through lastError', () async {
      final svc = FakeVoiceService(
        permission: PlatformPermissionStatus.denied,
        errorOnFail: VoiceError.permissionDenied,
      );
      expect(await svc.ensurePermission(), PlatformPermissionStatus.denied);
      // The real permission prompt happens inside startListening; when
      // it fails the service reports the denial via lastError so the UI
      // can show the right message instead of a generic failure.
      final started = await svc.startListening(
        onResult: (_) {},
        onLevel: (_) {},
      );
      expect(started, isFalse);
      expect(svc.lastError, VoiceError.permissionDenied);
    });

    test('unavailable device cannot start a session', () async {
      final svc = FakeVoiceService(
        available: false,
        errorOnFail: VoiceError.unavailable,
      );
      final started = await svc.startListening(onResult: (_) {});
      expect(started, isFalse);
      expect(svc.isListening, isFalse);
      expect(svc.lastError, VoiceError.unavailable);
    });

    test('cancel clears listening state', () async {
      final svc = FakeVoiceService();
      await svc.startListening(onResult: (_) {});
      await svc.cancelListening();
      expect(svc.isListening, isFalse);
      expect(svc.cancelListeningCalls, 1);
    });

    test('VoiceResult carries the recognized text + finality', () {
      const partial = VoiceResult(text: 'hello', finalResult: false);
      const final_ = VoiceResult(text: 'hello world', finalResult: true);
      expect(partial.finalResult, isFalse);
      expect(final_.finalResult, isTrue);
      expect(final_.text, 'hello world');
    });

    test('localeId is forwarded to the engine', () async {
      final svc = FakeVoiceService();
      await svc.startListening(onResult: (_) {}, localeId: 'zh-CN');
      expect(svc.lastLocaleId, 'zh-CN');
    });

    test('localeId is null by default (system-locale fallback)', () async {
      final svc = FakeVoiceService();
      await svc.startListening(onResult: (_) {});
      expect(svc.lastLocaleId, isNull);
    });
  });
}
