import '../../models/location_result.dart';
import 'calendar_service.dart' show PlatformPermissionStatus;
import 'location_service.dart';

class LocationServiceStub implements LocationService {
  @override
  Future<PlatformPermissionStatus> ensurePermission() async =>
      PlatformPermissionStatus.notSupported;

  @override
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 10),
  }) {
    throw UnsupportedError(
      'Location service is not supported on this platform',
    );
  }
}
