import 'autostart_service.dart';

/// No-op autostart implementation for mobile / web. Used when the
/// desktop impl can't be loaded because the host platform isn't
/// desktop (e.g. the test suite runs on `dart:io` desktop but the
/// concrete impl failed to write — we still want the UI to
/// gracefully no-op).
class AutostartServiceStub implements AutostartService {
  const AutostartServiceStub();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<bool?> setEnabled(bool enabled) async => null;
}
