import 'dart:io' show Platform;

import 'location_service.dart';
import 'location_service_io.dart' as io;
import 'location_service_ip.dart' as ip;
import 'location_service_stub.dart' as stub;

LocationService createLocationService() {
  if (Platform.isAndroid || Platform.isIOS) {
    return io.LocationServiceIo();
  }
  return ip.LocationServiceIp();
}

/// Test-only factory. Returns a stub that throws on every call so
/// callers can assert that the IP path is *not* taken.
LocationService createLocationServiceStub() => stub.LocationServiceStub();
