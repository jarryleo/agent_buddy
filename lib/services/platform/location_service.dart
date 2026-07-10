import '../../models/location_result.dart';
import 'calendar_service.dart' show PlatformPermissionStatus;

abstract class LocationService {
  Future<PlatformPermissionStatus> ensurePermission();
  Future<LocationResult> getCurrentLocation({Duration timeout});
}

typedef LocationServiceBuilder = LocationService Function();
