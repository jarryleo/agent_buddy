import 'dart:convert';

import 'package:agent_buddy/models/google_sheet_config.dart';
import 'package:agent_buddy/services/google_sheets_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _testCreds = GoogleOAuthCredentials(
  clientId: 'test-client-id',
  clientSecret: 'test-client-secret',
  authUri: 'https://example.com/auth',
  tokenUri: 'https://example.com/token',
  loopbackRedirectUri: 'http://127.0.0.1',
);

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  group('GoogleSheetConfig (model)', () {
    test('isFullyConfigured requires both id and tokens', () {
      const c = GoogleSheetConfig();
      expect(c.isFullyConfigured, isFalse);
      const withId = GoogleSheetConfig(spreadsheetId: 'abc');
      expect(withId.isFullyConfigured, isFalse);
      const withToken = GoogleSheetConfig(
        spreadsheetId: 'abc',
        accessToken: 'tok',
      );
      expect(withToken.isFullyConfigured, isTrue);
    });

    test('needsTokenRefresh treats unset expiry as "still valid"', () {
      const c = GoogleSheetConfig(accessToken: 'tok', refreshToken: 'ref');
      expect(c.needsTokenRefresh, isFalse);
    });

    test('needsTokenRefresh flips true within 5 min of expiry', () {
      final soon = DateTime.now()
          .add(const Duration(minutes: 3))
          .millisecondsSinceEpoch;
      final c = GoogleSheetConfig(
        accessToken: 'tok',
        refreshToken: 'ref',
        tokenExpiresAtMs: soon,
      );
      expect(c.needsTokenRefresh, isTrue);
    });

    test('round-trips through raw JSON', () {
      const c = GoogleSheetConfig(
        spreadsheetId: 'ss-id',
        defaultTab: 'Sales',
        accessToken: 'a',
        refreshToken: 'r',
        tokenExpiresAtMs: 12345,
        authedEmail: 'me@x.com',
      );
      final back = GoogleSheetConfig.fromRawJson(c.toRawJson());
      expect(back.spreadsheetId, c.spreadsheetId);
      expect(back.defaultTab, c.defaultTab);
      expect(back.accessToken, c.accessToken);
      expect(back.refreshToken, c.refreshToken);
      expect(back.tokenExpiresAtMs, c.tokenExpiresAtMs);
      expect(back.authedEmail, c.authedEmail);
    });
  });

  group('GoogleSheetsService — HTTP-backed Sheets API', () {
    test('listTabs returns tab names from the spreadsheet', () async {
      final client = MockClient((req) async {
        expect(req.url.path, contains('/spreadsheets/ss-id'));
        expect(req.url.queryParameters['fields'], contains('title'));
        return http.Response(
          jsonEncode({
            'sheets': [
              {
                'properties': {'title': 'Sheet1'},
              },
              {
                'properties': {'title': 'Sales'},
              },
            ],
          }),
          200,
        );
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
        urlLauncher: (_) async => true,
      );
      await svc.load();
      final tabs = await svc.listTabs();
      expect(tabs, ['Sheet1', 'Sales']);
      expect(svc.availableTabs, ['Sheet1', 'Sales']);
    });

    test('readRange decodes a 2D values array', () async {
      final client = MockClient((req) async {
        expect(req.url.path, contains('/values/'));
        return http.Response(
          jsonEncode({
            'range': 'Sheet1!A1:B2',
            'values': [
              ['a', 'b'],
              ['c', 4],
            ],
          }),
          200,
        );
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      final values = await svc.readRange('A1:B2', tab: 'Sheet1');
      expect(values, [
        ['a', 'b'],
        ['c', 4],
      ]);
    });

    test(
      'updateRange sends USER_ENTERED and returns mutation summary',
      () async {
        final client = MockClient((req) async {
          expect(req.method, 'PUT');
          expect(req.url.queryParameters['valueInputOption'], 'USER_ENTERED');
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['values'], [
            ['a', 'b'],
          ]);
          return http.Response(
            jsonEncode({
              'updatedRange': 'Sheet1!A1:B1',
              'updatedRows': 1,
              'updatedColumns': 2,
              'updatedCells': 2,
            }),
            200,
          );
        });
        final svc = GoogleSheetsService(
          storage: _FakeStorage(_readyConfig()),
          httpClient: client,
          credentialsLoader: () async => _testCreds,
        );
        await svc.load();
        final result = await svc.updateRange('A1:B1', [
          ['a', 'b'],
        ], tab: 'Sheet1');
        expect(result.updatedRange, 'Sheet1!A1:B1');
        expect(result.updatedCells, 2);
      },
    );

    test('appendRows uses insertDataOption=INSERT_ROWS', () async {
      final client = MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.queryParameters['insertDataOption'], 'INSERT_ROWS');
        return http.Response(
          jsonEncode({
            'updatedRange': 'Sheet1!A5:B5',
            'updatedRows': 1,
            'updatedColumns': 2,
            'updatedCells': 2,
          }),
          200,
        );
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      await svc.appendRows('A1:B1', [
        ['x'],
      ], tab: 'Sheet1');
    });

    test('clearRange hits the :clear endpoint', () async {
      final client = MockClient((req) async {
        expect(req.url.path, contains(':clear'));
        return http.Response(
          jsonEncode({'clearedRange': 'Sheet1!A1:B10'}),
          200,
        );
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      await svc.clearRange('A1:B10', tab: 'Sheet1');
    });

    test('batchUpdate forwards the body verbatim', () async {
      final client = MockClient((req) async {
        expect(req.url.path, endsWith(':batchUpdate'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['requests'], [
          {
            'addSheet': {
              'properties': {'title': 'NewTab'},
            },
          },
        ]);
        return http.Response(
          jsonEncode({
            'replies': [
              {
                'addSheet': {
                  'properties': {'sheetId': 99, 'title': 'NewTab'},
                },
              },
            ],
          }),
          200,
        );
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      final result = await svc.batchUpdate({
        'requests': [
          {
            'addSheet': {
              'properties': {'title': 'NewTab'},
            },
          },
        ],
      });
      expect((result['replies'] as List).length, 1);
    });

    test('fetchSheetProperties returns (sheetId, title) pairs', () async {
      final client = MockClient((req) async {
        expect(req.url.queryParameters['fields'], contains('sheetId'));
        return http.Response(
          jsonEncode({
            'sheets': [
              {
                'properties': {'sheetId': 0, 'title': 'Sheet1'},
              },
              {
                'properties': {'sheetId': 123, 'title': 'Sales'},
              },
            ],
          }),
          200,
        );
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      final props = await svc.fetchSheetProperties('tok');
      expect(props, hasLength(2));
      expect(props[0].sheetId, 0);
      expect(props[1].title, 'Sales');
    });

    test('401 flips state to error and surfaces a friendly message', () async {
      final client = MockClient((_) async => http.Response('nope', 401));
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      await expectLater(svc.listTabs(), throwsA(isA<StateError>()));
      expect(svc.state, GoogleSheetAuthState.error);
      expect(svc.stateError, contains('重新测试连接'));
    });
  });

  group('GoogleSheetsService — token refresh', () {
    test('refreshes the access token when close to expiry', () async {
      // Seed an almost-expired access token + a refresh token.
      final expiringSoon = DateTime.now()
          .add(const Duration(seconds: 30))
          .millisecondsSinceEpoch;
      final cfg = _readyConfig().copyWith(
        accessToken: 'old-tok',
        refreshToken: 'refresh-tok',
        tokenExpiresAtMs: expiringSoon,
      );
      String? lastAuth;
      final client = MockClient((req) async {
        if (req.url.toString().contains('example.com/token')) {
          lastAuth = req.body;
          return http.Response(
            jsonEncode({'access_token': 'new-tok', 'expires_in': 3600}),
            200,
          );
        }
        // The subsequent Sheets call should now be authorized with
        // the new token.
        lastAuth = req.headers['Authorization'];
        return http.Response(jsonEncode({'sheets': []}), 200);
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(cfg),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      await svc.listTabs();
      expect(lastAuth, contains('new-tok'));
    });

    test('concurrent refreshes share a single round-trip', () async {
      var refreshCalls = 0;
      final cfg = _readyConfig().copyWith(
        accessToken: 'old',
        refreshToken: 'ref',
        tokenExpiresAtMs: 0, // force refresh
      );
      final client = MockClient((req) async {
        if (req.url.toString().contains('example.com/token')) {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(
            jsonEncode({
              'access_token': 'tok-$refreshCalls',
              'expires_in': 3600,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'sheets': []}), 200);
      });
      final svc = GoogleSheetsService(
        storage: _FakeStorage(cfg),
        httpClient: client,
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      // Fire two listTabs in parallel; the refresh should de-dup.
      await Future.wait([svc.listTabs(), svc.listTabs()]);
      expect(refreshCalls, 1);
    });
  });

  group('GoogleSheetsService — state machine', () {
    test('load() on an empty config yields the unconfigured state', () async {
      final svc = GoogleSheetsService(
        storage: _FakeStorage(GoogleSheetConfig.empty),
        httpClient: MockClient((_) async => http.Response('', 200)),
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      expect(svc.state, GoogleSheetAuthState.unconfigured);
      expect(svc.isReady, isFalse);
    });

    test('id-only config is unauthorized', () async {
      final svc = GoogleSheetsService(
        storage: _FakeStorage(const GoogleSheetConfig(spreadsheetId: 'ss-id')),
        httpClient: MockClient((_) async => http.Response('', 200)),
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      expect(svc.state, GoogleSheetAuthState.unauthorized);
      expect(svc.isReady, isFalse);
    });

    test('id + tokens is ready', () async {
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: MockClient((_) async => http.Response('', 200)),
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      expect(svc.state, GoogleSheetAuthState.authorized);
      expect(svc.isReady, isTrue);
    });

    test('signOut drops tokens and flips to unauthorized', () async {
      final svc = GoogleSheetsService(
        storage: _FakeStorage(_readyConfig()),
        httpClient: MockClient((_) async => http.Response('', 200)),
        credentialsLoader: () async => _testCreds,
      );
      await svc.load();
      await svc.signOut();
      expect(svc.config.accessToken, isNull);
      expect(svc.config.refreshToken, isNull);
      expect(svc.state, GoogleSheetAuthState.unauthorized);
    });
  });
}

GoogleSheetConfig _readyConfig() => const GoogleSheetConfig(
  spreadsheetId: 'ss-id',
  defaultTab: 'Sheet1',
  accessToken: 'tok',
  refreshToken: 'ref',
  tokenExpiresAtMs: 9999999999999,
);

class _FakeStorage implements StorageService {
  _FakeStorage(this._config);
  GoogleSheetConfig _config;

  @override
  GoogleSheetConfig loadGoogleSheetConfig() => _config;

  @override
  Future<void> saveGoogleSheetConfig(GoogleSheetConfig config) async {
    _config = config;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not stubbed');
}
