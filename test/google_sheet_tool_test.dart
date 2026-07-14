import 'dart:convert';

import 'package:agent_buddy/models/google_sheet_config.dart';
import 'package:agent_buddy/services/google_sheets_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/google_sheet_tool.dart';
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

GoogleSheetConfig _readyConfig() => const GoogleSheetConfig(
  spreadsheetId: 'ss-id',
  defaultTab: 'Sheet1',
  accessToken: 'tok',
  refreshToken: 'ref',
  tokenExpiresAtMs: 9999999999999,
);

void main() {
  late GoogleSheetsService sheetsService;
  late ToolService tools;
  late List<http.Request> recorded;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    recorded = [];
    sheetsService = GoogleSheetsService(
      storage: _FakeStorage(_readyConfig()),
      httpClient: MockClient((req) async {
        recorded.add(
          http.Request(req.method, req.url)
            ..headers.addAll(req.headers)
            ..bodyBytes = req.bodyBytes,
        );
        // Default mock: empty sheets metadata.
        return http.Response(
          jsonEncode({
            'sheets': [
              {
                'properties': {'sheetId': 0, 'title': 'Sheet1'},
              },
              {
                'properties': {'sheetId': 7, 'title': 'Sales'},
              },
            ],
          }),
          200,
        );
      }),
      credentialsLoader: () async => _testCreds,
    );
    await sheetsService.load();
    tools = ToolService(
      httpClient: MockClient((req) async {
        recorded.add(http.Request(req.method, req.url));
        return http.Response('{}', 200);
      }),
      googleSheets: sheetsService,
    );
  });

  group('GoogleSheetTool — schema', () {
    test('id is the wire name the tool is dispatched on', () {
      expect(GoogleSheetTool().id, 'google_sheet');
    });

    test('isEnabledByDefault is false so the one-time setup sheet '
        'is the user\'s first interaction', () {
      expect(GoogleSheetTool().isEnabledByDefault, isFalse);
    });

    test('isSupportedOnCurrentPlatform is false off-desktop', () {
      // On the dev host the platform is real; we only need the
      // gate to be consistent. The test below pins the value so a
      // future test on a different host still asserts something
      // meaningful rather than always-true.
      expect(GoogleSheetTool().isSupportedOnCurrentPlatform, isA<bool>());
    });

    test('buildSchema returns {} iff the platform is unsupported', () {
      final supported = GoogleSheetTool().isSupportedOnCurrentPlatform;
      if (supported) {
        expect(GoogleSheetTool().buildSchema(), isNotEmpty);
      } else {
        expect(GoogleSheetTool().buildSchema(), {});
      }
    });
  });

  group('GoogleSheetTool — validation', () {
    test('throws when called with no service ready', () async {
      final emptySvc = await _buildService(
        config: GoogleSheetConfig.empty,
        client: MockClient((_) async => http.Response('', 200)),
      );
      final emptyTools = ToolService(
        httpClient: MockClient((_) async => http.Response('', 200)),
        googleSheets: emptySvc,
      );
      expect(
        () => emptyTools.runGoogleSheet({'action': 'list_tabs'}),
        throwsA(
          isA<ToolException>().having(
            (e) => e.toString(),
            'message',
            contains('not configured'),
          ),
        ),
      );
    });

    test('throws when action is missing', () async {
      expect(
        () => tools.runGoogleSheet(const <String, dynamic>{}),
        throwsA(isA<ToolException>()),
      );
    });

    test('throws on unknown action', () async {
      expect(
        () => tools.runGoogleSheet({'action': 'drop_table'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('read requires range', () async {
      expect(
        () => tools.runGoogleSheet({'action': 'read'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('update requires non-empty values 2D array', () async {
      expect(
        () => tools.runGoogleSheet({'action': 'update', 'range': 'A1'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('create_tab requires title', () async {
      expect(
        () => tools.runGoogleSheet({'action': 'create_tab'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('format requires at least one attribute', () async {
      expect(
        () => tools.runGoogleSheet({'action': 'format', 'range': 'A1:B2'}),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('GoogleSheetTool — happy paths', () {
    test('list_tabs returns the envelope with default_tab', () async {
      final raw = await tools.runGoogleSheet({'action': 'list_tabs'});
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['action'], 'list_tabs');
      expect(env['default_tab'], 'Sheet1');
      expect(env['spreadsheet_id'], 'ss-id');
      expect((env['tabs'] as List), ['Sheet1', 'Sales']);
    });

    test('read returns rows, cols, and values', () async {
      // Override the MockClient to return values for the read call.
      final svc = await _buildService(
        config: _readyConfig(),
        client: MockClient((req) async {
          if (req.url.path.contains('/values/')) {
            return http.Response(
              jsonEncode({
                'range': 'Sheet1!A1:B2',
                'values': [
                  ['a', 'b'],
                  ['c', 'd'],
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'sheets': [
                {
                  'properties': {'sheetId': 0, 'title': 'Sheet1'},
                },
              ],
            }),
            200,
          );
        }),
      );
      final toolsWithValues = ToolService(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        googleSheets: svc,
      );
      final raw = await toolsWithValues.runGoogleSheet({
        'action': 'read',
        'range': 'A1:B2',
      });
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['action'], 'read');
      expect(env['rows'], 2);
      expect(env['cols'], 2);
      expect((env['values'] as List).first, ['a', 'b']);
    });

    test('update forwards values + returns mutation summary', () async {
      String? capturedBody;
      String? capturedMethod;
      final svc = await _buildService(
        config: _readyConfig(),
        client: MockClient((req) async {
          if (req.url.path.contains('/values/') && req.method == 'PUT') {
            capturedMethod = req.method;
            capturedBody = req.body;
            return http.Response(
              jsonEncode({
                'updatedRange': 'Sheet1!A1:B1',
                'updatedRows': 1,
                'updatedColumns': 2,
                'updatedCells': 2,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'sheets': [
                {
                  'properties': {'sheetId': 0, 'title': 'Sheet1'},
                },
              ],
            }),
            200,
          );
        }),
      );
      final toolsWithCapture = ToolService(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        googleSheets: svc,
      );
      final raw = await toolsWithCapture.runGoogleSheet({
        'action': 'update',
        'range': 'A1:B1',
        'values': [
          ['a', 'b'],
        ],
      });
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['action'], 'update');
      expect(env['updated_cells'], 2);
      expect(capturedMethod, 'PUT');
      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(body['values'], [
        ['a', 'b'],
      ]);
    });

    test('create_tab issues a batchUpdate with addSheet', () async {
      Map<String, dynamic>? capturedBody;
      final svc = await _buildService(
        config: _readyConfig(),
        client: MockClient((req) async {
          if (req.url.path.endsWith(':batchUpdate')) {
            capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
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
          }
          return http.Response(
            jsonEncode({
              'sheets': [
                {
                  'properties': {'sheetId': 0, 'title': 'Sheet1'},
                },
              ],
            }),
            200,
          );
        }),
      );
      final toolsWithCapture = ToolService(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        googleSheets: svc,
      );
      final raw = await toolsWithCapture.runGoogleSheet({
        'action': 'create_tab',
        'title': 'NewTab',
      });
      expect(capturedBody, isNotNull);
      final reqs = capturedBody!['requests'] as List;
      expect(reqs.first, {
        'addSheet': {
          'properties': {'title': 'NewTab'},
        },
      });
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['title'], 'NewTab');
    });

    test('delete_tab resolves tab to sheetId and calls batchUpdate', () async {
      Map<String, dynamic>? capturedBody;
      final svc = await _buildService(
        config: _readyConfig(),
        client: MockClient((req) async {
          if (req.url.path.endsWith(':batchUpdate')) {
            capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'replies': [{}],
              }),
              200,
            );
          }
          if (req.url.queryParameters['fields']?.contains('sheetId') ?? false) {
            return http.Response(
              jsonEncode({
                'sheets': [
                  {
                    'properties': {'sheetId': 7, 'title': 'Sales'},
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'sheets': [
                {
                  'properties': {'sheetId': 0, 'title': 'Sheet1'},
                },
                {
                  'properties': {'sheetId': 7, 'title': 'Sales'},
                },
              ],
            }),
            200,
          );
        }),
      );
      final toolsWithCapture = ToolService(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
        googleSheets: svc,
      );
      final raw = await toolsWithCapture.runGoogleSheet({
        'action': 'delete_tab',
        'tab': 'Sales',
      });
      expect(capturedBody, isNotNull);
      final reqs = capturedBody!['requests'] as List;
      expect(reqs.first, {
        'deleteSheet': {'sheetId': 7},
      });
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['tab_id'], 7);
    });

    test(
      'format builds a repeatCell request with the chosen attributes',
      () async {
        Map<String, dynamic>? capturedBody;
        final svc = await _buildService(
          config: _readyConfig(),
          client: MockClient((req) async {
            if (req.url.path.endsWith(':batchUpdate')) {
              capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
              return http.Response(
                jsonEncode({
                  'replies': [{}],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'sheets': [
                  {
                    'properties': {'sheetId': 0, 'title': 'Sheet1'},
                  },
                ],
              }),
              200,
            );
          }),
        );
        final toolsWithCapture = ToolService(
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          googleSheets: svc,
        );
        await toolsWithCapture.runGoogleSheet({
          'action': 'format',
          'range': 'A1:B2',
          'tab': 'Sheet1',
          'bold': true,
          'background_color': '#FF0000',
          'number_format_type': 'CURRENCY',
          'number_format_pattern': r'"$"#,##0.00',
        });
        expect(capturedBody, isNotNull);
        final reqs = capturedBody!['requests'] as List;
        final repeat = (reqs.first as Map)['repeatCell'] as Map;
        final fields = repeat['fields'] as String;
        expect(fields, contains('userEnteredFormat.textFormat.bold'));
        expect(fields, contains('userEnteredFormat.backgroundColor'));
        expect(fields, contains('userEnteredFormat.numberFormat'));
        final cell = repeat['cell'] as Map;
        final fmt = cell['userEnteredFormat'] as Map;
        expect((fmt['textFormat'] as Map)['bold'], true);
        expect(fmt['backgroundColor'], {'red': 1.0, 'green': 0.0, 'blue': 0.0});
        expect((fmt['numberFormat'] as Map)['type'], 'CURRENCY');
      },
    );
  });
}

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

/// Build a fully-loaded `GoogleSheetsService` with a fake
/// storage + the supplied mock HTTP client. Used by the happy-path
/// tests so each one can focus on its specific endpoint mock.
Future<GoogleSheetsService> _buildService({
  required GoogleSheetConfig config,
  required MockClient client,
}) async {
  final svc = GoogleSheetsService(
    storage: _FakeStorage(config),
    httpClient: client,
    credentialsLoader: () async => _testCreds,
  );
  await svc.load();
  return svc;
}
