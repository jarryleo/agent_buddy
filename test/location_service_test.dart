import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/models/location_result.dart';
import 'package:agent_buddy/services/platform/calendar_service.dart'
    show PlatformPermissionStatus;
import 'package:agent_buddy/services/platform/location_service.dart';
import 'package:agent_buddy/services/platform/location_service_io.dart';
import 'package:agent_buddy/services/platform/location_service_ip.dart';
import 'package:agent_buddy/services/platform/location_service_stub.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('LocationServiceIp', () {
    test('parses a well-formed ip-api response', () async {
      final body = jsonEncode({
        'status': 'success',
        'lat': 31.2304,
        'lon': 121.4737,
        'city': 'Shanghai',
        'regionName': 'Shanghai',
        'country': 'China',
        'countryCode': 'CN',
        'timezone': 'Asia/Shanghai',
        'isp': 'China Telecom',
      });
      final client = _StubClient((req) async => http.Response(body, 200));
      final svc = LocationServiceIp(
        client: client,
        endpoint: Uri.parse('http://example.invalid/json'),
      );
      final result = await svc.getCurrentLocation();
      expect(result.source, 'ip');
      expect(result.latitude, closeTo(31.2304, 1e-6));
      expect(result.longitude, closeTo(121.4737, 1e-6));
      expect(result.city, 'Shanghai');
      expect(result.countryCode, 'CN');
      expect(result.timezone, 'Asia/Shanghai');
      expect(result.isp, 'China Telecom');
    });

    test('throws on status=fail body', () async {
      final body = jsonEncode({'status': 'fail', 'message': 'private range'});
      final client = _StubClient((req) async => http.Response(body, 200));
      final svc = LocationServiceIp(
        client: client,
        endpoint: Uri.parse('http://example.invalid/json'),
      );
      expect(() => svc.getCurrentLocation(), throwsA(isA<FormatException>()));
    });

    test('throws on non-2xx status', () async {
      final client = _StubClient(
        (req) async => http.Response('rate limited', 429),
      );
      final svc = LocationServiceIp(
        client: client,
        endpoint: Uri.parse('http://example.invalid/json'),
      );
      expect(() => svc.getCurrentLocation(), throwsA(isA<SocketException>()));
    });

    test('throws when lat/lon missing', () async {
      final body = jsonEncode({'status': 'success', 'city': 'X'});
      final client = _StubClient((req) async => http.Response(body, 200));
      final svc = LocationServiceIp(
        client: client,
        endpoint: Uri.parse('http://example.invalid/json'),
      );
      expect(() => svc.getCurrentLocation(), throwsA(isA<FormatException>()));
    });

    test(
      'ensurePermission always returns granted (no prompt needed)',
      () async {
        final svc = LocationServiceIp(
          client: _StubClient((req) async => http.Response('{}', 200)),
        );
        final status = await svc.ensurePermission();
        expect(status.name, 'granted');
      },
    );
  });

  group('LocationServiceStub', () {
    test('ensurePermission reports notSupported', () async {
      final stub = LocationServiceStub();
      expect((await stub.ensurePermission()).name, 'notSupported');
    });

    test('getCurrentLocation throws UnsupportedError', () async {
      final stub = LocationServiceStub();
      expect(() => stub.getCurrentLocation(), throwsA(isA<UnsupportedError>()));
    });
  });

  group('LocationServiceIo (MethodChannel mocking)', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    const channel = MethodChannel('agent_buddy/location');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'ensurePermission maps granted / denied / permanently_denied',
      () async {
        final cases = <Map<String, dynamic>, PlatformPermissionStatus>{
          {'granted': true, 'status': 'granted'}:
              PlatformPermissionStatus.granted,
          {'granted': false, 'status': 'permanently_denied'}:
              PlatformPermissionStatus.permanentlyDenied,
          {'granted': false, 'status': 'denied'}:
              PlatformPermissionStatus.denied,
        };
        for (final entry in cases.entries) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'ensurePermission') return entry.key;
                return null;
              });
          final svc = LocationServiceIo();
          final status = await svc.ensurePermission();
          expect(status, entry.value, reason: 'for ${entry.key}');
        }
      },
    );

    test(
      'ensurePermission returns notSupported on MissingPluginException',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw MissingPluginException('not wired');
            });
        final svc = LocationServiceIo();
        expect(
          (await svc.ensurePermission()),
          PlatformPermissionStatus.notSupported,
        );
      },
    );

    test('getCurrentLocation translates MethodChannel payload', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getCurrentLocation') {
              return {
                'latitude': 39.9,
                'longitude': 116.4,
                'accuracyMeters': 12.0,
                'city': 'Beijing',
                'region': 'Beijing',
                'country': 'China',
                'countryCode': 'CN',
                'timezone': 'Asia/Shanghai',
                'source': 'gps',
                'fetchedAtMs': 1752123456789,
              };
            }
            return null;
          });
      final svc = LocationServiceIo();
      final loc = await svc.getCurrentLocation();
      expect(loc.source, 'gps');
      expect(loc.city, 'Beijing');
      expect(loc.latitude, closeTo(39.9, 1e-6));
      expect(loc.countryCode, 'CN');
    });

    test(
      'getCurrentLocation throws NO_LOCATION when the bridge returns null',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'getCurrentLocation') return null;
              return null;
            });
        final svc = LocationServiceIo();
        expect(
          () => svc.getCurrentLocation(),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'NO_LOCATION',
            ),
          ),
        );
      },
    );
  });

  group('runLocation (desktop host -> IP path)', () {
    test(
      'returns a well-formed envelope when the IP service responds',
      () async {
        final body = jsonEncode({
          'status': 'success',
          'lat': 39.9042,
          'lon': 116.4074,
          'city': 'Beijing',
          'regionName': 'Beijing',
          'country': 'China',
          'countryCode': 'CN',
          'timezone': 'Asia/Shanghai',
          'isp': 'China Unicom',
        });
        final client = _StubClient((req) async => http.Response(body, 200));
        final tools = ToolService(
          locationBuilder: () => LocationServiceIp(
            client: client,
            endpoint: Uri.parse('http://example.invalid/json'),
          ),
        );
        final raw = await tools.runLocation({'action': 'get'});
        final envelope = jsonDecode(raw) as Map<String, dynamic>;
        expect(envelope['action'], 'get');
        final loc = envelope['location'] as Map<String, dynamic>;
        expect(loc['source'], 'ip');
        expect(loc['city'], 'Beijing');
        expect(loc['countryCode'], 'CN');
        expect(loc['latitude'], closeTo(39.9042, 1e-6));
      },
    );

    test('propagates socket errors as a friendly ToolException', () async {
      final client = _StubClient((req) async {
        throw const SocketException('no network in test');
      });
      final tools = ToolService(
        locationBuilder: () => LocationServiceIp(
          client: client,
          endpoint: Uri.parse('http://example.invalid/json'),
        ),
      );
      try {
        await tools.runLocation({'action': 'get'});
        fail('expected ToolException');
      } on ToolException catch (e) {
        expect(e.message, contains('no network in test'));
      }
    });

    test('unknown action throws ToolException', () async {
      final tools = ToolService(
        locationBuilder: () => LocationServiceIp(
          client: _StubClient((req) async => http.Response('{}', 200)),
        ),
      );
      expect(
        () => tools.runLocation({'action': 'explode'}),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('runLocation permission states', () {
    test('granted -> fetch is called and the envelope comes back', () async {
      final svc = _FakeLocationService(
        ensureStatus: PlatformPermissionStatus.granted,
        fix: _dummyFix,
      );
      final tools = ToolService(locationBuilder: () => svc);
      final raw = await tools.runLocation({'action': 'get'});
      expect(svc.fetchCalls, 1);
      expect(raw, contains('"source":"gps"'));
      expect(raw, contains('"latitude":31.2304'));
    });

    test(
      'denied (waiting on the OS dialog) -> fetch still gets called, '
      'so the native bridge can park the request until the user answers',
      () async {
        final svc = _FakeLocationService(
          ensureStatus: PlatformPermissionStatus.denied,
          fix: _dummyFix,
        );
        final tools = ToolService(locationBuilder: () => svc);
        final raw = await tools.runLocation({'action': 'get'});
        expect(svc.fetchCalls, 1);
        expect(raw, contains('"source":"gps"'));
      },
    );

    test(
      'permanentlyDenied -> fetch is NOT called; surfaces a clear error',
      () async {
        final svc = _FakeLocationService(
          ensureStatus: PlatformPermissionStatus.permanentlyDenied,
          fix: _dummyFix,
        );
        final tools = ToolService(locationBuilder: () => svc);
        try {
          await tools.runLocation({'action': 'get'});
          fail('expected ToolException');
        } on ToolException catch (e) {
          expect(e.message, contains('permanently denied'));
        }
        expect(svc.fetchCalls, 0);
      },
    );

    test('notSupported -> fetch is NOT called; clear error message', () async {
      final svc = _FakeLocationService(
        ensureStatus: PlatformPermissionStatus.notSupported,
        fix: _dummyFix,
      );
      final tools = ToolService(locationBuilder: () => svc);
      try {
        await tools.runLocation({'action': 'get'});
        fail('expected ToolException');
      } on ToolException catch (e) {
        expect(e.message, contains('native bridge not registered'));
      }
      expect(svc.fetchCalls, 0);
    });

    test('PlatformException(PERMISSION_DENIED) is translated to a clear '
        'ToolException (e.g. user just tapped "Don\'t Allow")', () async {
      final svc = _FakeLocationService(
        ensureStatus: PlatformPermissionStatus.granted,
        fetchError: PlatformException(
          code: 'PERMISSION_DENIED',
          message: 'Location permission was denied',
        ),
      );
      final tools = ToolService(locationBuilder: () => svc);
      try {
        await tools.runLocation({'action': 'get'});
        fail('expected ToolException');
      } on ToolException catch (e) {
        expect(e.message, contains('permission denied'));
      }
    });

    test('PlatformException(LOCATION_TIMEOUT) is translated to a clear '
        'ToolException', () async {
      final svc = _FakeLocationService(
        ensureStatus: PlatformPermissionStatus.granted,
        fetchError: PlatformException(
          code: 'LOCATION_TIMEOUT',
          message: 'timed out',
        ),
      );
      final tools = ToolService(locationBuilder: () => svc);
      try {
        await tools.runLocation({'action': 'get'});
        fail('expected ToolException');
      } on ToolException catch (e) {
        expect(e.message.toLowerCase(), contains('timed out'));
      }
    });

    test('PlatformException(LOCATION_UNAVAILABLE) is translated to a clear '
        'ToolException', () async {
      final svc = _FakeLocationService(
        ensureStatus: PlatformPermissionStatus.granted,
        fetchError: PlatformException(
          code: 'LOCATION_UNAVAILABLE',
          message: 'no fix available',
        ),
      );
      final tools = ToolService(locationBuilder: () => svc);
      try {
        await tools.runLocation({'action': 'get'});
        fail('expected ToolException');
      } on ToolException catch (e) {
        expect(e.message.toLowerCase(), contains('unavailable'));
      }
    });
  });
}

class _FakeLocationService implements LocationService {
  _FakeLocationService({required this.ensureStatus, this.fix, this.fetchError});

  final PlatformPermissionStatus ensureStatus;
  final LocationResult? fix;
  final Object? fetchError;
  int fetchCalls = 0;

  @override
  Future<PlatformPermissionStatus> ensurePermission() async => ensureStatus;

  @override
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    fetchCalls++;
    if (fetchError != null) throw fetchError!;
    return fix ?? _dummyFix;
  }
}

final LocationResult _dummyFix = LocationResult.fromGps(
  latitude: 31.2304,
  longitude: 121.4737,
  accuracyMeters: 50.0,
  city: 'Shanghai',
  country: 'China',
  countryCode: 'CN',
  timezone: 'Asia/Shanghai',
);

class _StubClient extends http.BaseClient {
  _StubClient(this._handler);
  final Future<http.Response> Function(http.BaseRequest req) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final resp = await _handler(request);
    return http.StreamedResponse(
      Stream.value(resp.bodyBytes),
      resp.statusCode,
      headers: resp.headers,
    );
  }
}
