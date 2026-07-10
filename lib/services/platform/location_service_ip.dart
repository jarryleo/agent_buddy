import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../../models/location_result.dart';
import 'calendar_service.dart' show PlatformPermissionStatus;
import 'location_service.dart';

/// IP-based geolocation for desktop / web. Calls a free, no-key
/// service ([ip-api.com]) to map the user's public IP to a coarse
/// city-level fix. This is the right answer for laptops and
/// workstations that have no GPS and don't need to prompt the user
/// for a permission dialog — accuracy is city-level (or worse for
/// mobile-network / VPN users), which is more than enough for
/// "what's the weather here" / "what's my timezone" use cases.
///
/// On Android / iOS the factory returns [LocationServiceIo] (real
/// GPS via the native bridge) instead, so this class is only used
/// on desktop / web.
class LocationServiceIp implements LocationService {
  LocationServiceIp({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _endpoint = endpoint ?? Uri.parse('http://ip-api.com/json/?lang=zh-CN');

  final http.Client _client;
  final Uri _endpoint;

  @override
  Future<PlatformPermissionStatus> ensurePermission() async =>
      PlatformPermissionStatus.granted;

  @override
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (kIsWeb) {
      throw const SocketException(
        'IP geolocation not supported in this environment',
      );
    }
    final http.Response resp;
    try {
      resp = await _client.get(_endpoint).timeout(timeout);
    } on TimeoutException {
      throw const SocketException('IP geolocation request timed out');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SocketException('IP geolocation returned HTTP ${resp.statusCode}');
    }
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw const FormatException(
        'IP geolocation response is not a JSON object',
      );
    }
    if (body['status'] == 'fail') {
      throw const FormatException('IP geolocation query failed');
    }
    final lat = (body['lat'] as num?)?.toDouble();
    final lon = (body['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      throw const FormatException('IP geolocation response missing lat/lon');
    }
    return LocationResult.fromIp(
      latitude: lat,
      longitude: lon,
      city: body['city'] as String?,
      region: body['regionName'] as String?,
      country: body['country'] as String?,
      countryCode: body['countryCode'] as String?,
      timezone: body['timezone'] as String?,
      isp: body['isp'] as String?,
    );
  }
}
