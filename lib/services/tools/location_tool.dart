import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;

import '../platform/calendar_service.dart' show PlatformPermissionStatus;
import '../tool_service.dart';
import 'tool_base.dart';

class LocationTool extends ToolBase {
  @override String get id => 'location';
  @override String get name => '位置';
  @override String get description => '获取当前位置(经纬度+城市+时区)。手机用 GPS(需授权),电脑/Web 靠 IP。';
  @override bool get isSupportedOnCurrentPlatform => true;

  @override Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'location', 'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['get'], 'description': '固定 get'},
            'timeout_ms': {'type': 'integer', 'description': '超时毫秒,默认 10000', 'default': 10000, 'minimum': 1000, 'maximum': 60000},
          },
          'required': const <String>[],
        },
      },
    };
  }

  @override
  Future<String> execute(Map<String, dynamic> args, ToolService services) async {
    final action = args['action'] as String? ?? 'get';
    switch (action) {
      case 'get':
        final timeoutMs = (args['timeout_ms'] as num?)?.toInt() ?? 10000;
        final timeout = Duration(milliseconds: timeoutMs);
        try {
          final location = services.location;
          final status = await location.ensurePermission();
          if (status == PlatformPermissionStatus.notSupported) {
            throw ToolException(
              'location tool is not available: native bridge not registered',
            );
          }
          if (status == PlatformPermissionStatus.permanentlyDenied) {
            throw ToolException(
              'location permission permanently denied; open system settings to enable it',
            );
          }
          final result = await location.getCurrentLocation(timeout: timeout);
          return jsonEncode({'action': 'get', 'location': result.toJson()});
        } on ToolException {
          rethrow;
        } on UnsupportedError catch (e) {
          throw ToolException('${e.message} (location)');
        } on MissingPluginException {
          throw ToolException(
            'location tool is not available: native bridge not registered',
          );
        } on PlatformException catch (e) {
          switch (e.code) {
            case 'PERMISSION_DENIED':
              throw ToolException(
                'location permission denied; please grant it in system settings',
              );
            case 'PERMANENTLY_DENIED':
              throw ToolException(
                'location permission permanently denied; open system settings to enable it',
              );
            case 'LOCATION_TIMEOUT':
              throw ToolException(
                'location request timed out; make sure GPS / network is available and try again',
              );
            case 'LOCATION_UNAVAILABLE':
              throw ToolException(
                'location unavailable; make sure location services are on and try again',
              );
            case 'NO_LOCATION':
              throw ToolException('no location returned by the platform');
            default:
              throw ToolException('location error: ${e.code}: ${e.message}');
          }
        } on TimeoutException {
          throw ToolException(
            'location request timed out; make sure GPS / network is available and try again',
          );
        } on SocketException catch (e) {
          throw ToolException('location error: ${e.message}');
        }
      default:
        throw ToolException('unknown action: $action (expected get)');
    }
  }
}
