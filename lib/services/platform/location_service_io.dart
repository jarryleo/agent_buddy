import 'package:flutter/services.dart';

import '../../models/location_result.dart';
import 'calendar_service.dart' show PlatformPermissionStatus;
import 'location_service.dart';

class LocationServiceIo implements LocationService {
  static const MethodChannel _channel = MethodChannel('agent_buddy/location');

  @override
  Future<PlatformPermissionStatus> ensurePermission() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'ensurePermission',
      );
      return _statusFromMap(result);
    } on MissingPluginException {
      return PlatformPermissionStatus.notSupported;
    } on PlatformException catch (e) {
      if (e.code == 'PERMANENTLY_DENIED') {
        return PlatformPermissionStatus.permanentlyDenied;
      }
      if (e.code == 'PERMISSION_DENIED') {
        return PlatformPermissionStatus.denied;
      }
      return PlatformPermissionStatus.denied;
    }
  }

  @override
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getCurrentLocation',
      {'timeoutMs': timeout.inMilliseconds},
    );
    if (raw == null) {
      throw PlatformException(
        code: 'NO_LOCATION',
        message: 'no location returned',
      );
    }
    return LocationResult.fromJson(raw.cast<String, dynamic>());
  }

  static PlatformPermissionStatus _statusFromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return PlatformPermissionStatus.denied;
    if (map['granted'] == true) return PlatformPermissionStatus.granted;
    switch (map['status']) {
      case 'permanently_denied':
        return PlatformPermissionStatus.permanentlyDenied;
      case 'denied':
        return PlatformPermissionStatus.denied;
      default:
        return PlatformPermissionStatus.denied;
    }
  }
}
