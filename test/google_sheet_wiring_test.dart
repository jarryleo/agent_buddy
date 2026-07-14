import 'dart:io';

import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/google_sheets_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const _creds = GoogleOAuthCredentials(
  clientId: 'test-client-id',
  clientSecret: 'test-client-secret',
  authUri: 'https://example.com/auth',
  tokenUri: 'https://example.com/token',
  loopbackRedirectUri: 'http://127.0.0.1',
);

/// End-to-end regression for the "two-instance" bug.
///
/// `main.dart` constructs a single `GoogleSheetsService` and wires
/// it into BOTH:
///   - the `ChangeNotifierProvider<GoogleSheetsService>` that
///     `SettingsProvider` listens to (so the tools tab toggle gate
///     can read the latest `isFullyConfigured` state), and
///   - the `ToolService` (so the settings sheet, the `google_sheet`
///     tool, and the rest of the tool runtime share the same
///     instance).
///
/// The original bug: `main.dart` only passed `storage` to
/// `ToolService`, which caused `ToolService` to spin up a *second*
/// `GoogleSheetsService` internally. The settings sheet's Save
/// handler wrote to the second instance, and `SettingsProvider`
/// (listening to the first) never saw the update — so the toggle
/// gate kept firing on every tap, popping the settings sheet back
/// open even after a successful save. On app restart, the
/// in-memory state of the second instance was lost, so the
/// settings sheet would show an empty form the next time the
/// user opened it — which looked like "the config was cleared".
///
/// These tests pin the wiring: the constructor must use the
/// injected instance when one is provided, and a fresh save via
/// the service must be visible to `SettingsProvider` in the same
/// frame.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late GoogleSheetsService sharedSheets;
  late ToolService toolService;
  late SettingsProvider settings;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_sheet_wiring_test_',
    );
    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();

    // The single source of truth — the same one `main.dart` builds.
    sharedSheets = GoogleSheetsService(
      storage: storage,
      httpClient: _StubClient(),
      credentialsLoader: () async => _creds,
    );
    await sharedSheets.load();

    // ToolService receives the shared instance (the fix). If
    // `googleSheets:` is ever dropped from this call site (the
    // original bug), the assertion at the top of the test below
    // fails.
    toolService = ToolService(
      storage: storage,
      googleSheets: sharedSheets,
      httpClient: _StubClient(),
    );

    // SettingsProvider listens to the same shared instance.
    settings = SettingsProvider(storage, sharedSheets);
    await settings.load();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test('ToolService.googleSheets is the SAME instance as the shared one', () {
    // The whole point of the fix: only one GoogleSheetsService
    // instance must exist in the running app. The setter on
    // ToolService must accept the shared instance and not create
    // its own.
    expect(identical(toolService.googleSheets, sharedSheets), isTrue);
  });

  test('regression: when ToolService is built WITHOUT the shared instance '
      '(the original bug), the SettingsProvider cannot see writes through '
      'it — toggle gate stays broken', () async {
    // Reproduce the original wiring: main.dart only passes
    // `storage`, so ToolService constructs its own internal
    // `GoogleSheetsService` instance. The settings sheet writes
    // to that internal instance, and `SettingsProvider` (which
    // listens to the *shared* instance) never sees the update.
    final brokenToolService = ToolService(
      storage: storage,
      httpClient: _StubClient(),
    );

    // Two different instances — this is the bug. The shared
    // instance is the one SettingsProvider listens to; the
    // ToolService's internal instance is the one the settings
    // sheet uses.
    expect(
      identical(brokenToolService.googleSheets, sharedSheets),
      isFalse,
      reason:
          'the bug would be invisible to the test if the '
          'constructor accepted the shared instance',
    );

    // Drive the same flow the settings sheet's Save button uses:
    // write through the ToolService's internal instance, not
    // through the shared one.
    await brokenToolService.googleSheets.updateSelection(
      spreadsheetId: 'ss-id',
      defaultTab: 'Sheet1',
    );
    await storage.saveGoogleSheetConfig(
      brokenToolService.googleSheets.config.copyWith(
        accessToken: 'tok',
        refreshToken: 'ref',
        tokenExpiresAtMs: 9999999999999,
      ),
    );
    await brokenToolService.googleSheets.load();

    // The shared instance has NOT been notified — so the
    // SettingsProvider's cached copy is still the fresh-install
    // default. The tools tab toggle gate would re-open the
    // settings sheet.
    expect(settings.googleSheetConfig.isFullyConfigured, isFalse);

    // Both consumers are out of sync — this is the visible
    // symptom of the bug.
    expect(brokenToolService.googleSheets.config.spreadsheetId, 'ss-id');
    expect(
      settings.googleSheetConfig.spreadsheetId,
      '',
      reason: 'shared SheetsService never received the write',
    );
  });

  test(
    'after save: settings.googleSheetConfig reflects the new state '
    'in the same frame (no async gap between sheet save and toggle gate)',
    () async {
      // Drive the same flow the settings sheet's Save button runs.
      await sharedSheets.updateSelection(
        spreadsheetId: 'ss-id',
        defaultTab: 'Sheet1',
      );
      await storage.saveGoogleSheetConfig(
        sharedSheets.config.copyWith(
          accessToken: 'tok',
          refreshToken: 'ref',
          tokenExpiresAtMs: 9999999999999,
          authedEmail: 'me@x.com',
        ),
      );
      await sharedSheets.load();

      // By the time `await sharedSheets.load()` returns, the
      // listener in SettingsProvider has already fired
      // synchronously and `_googleSheetConfig` reflects the new
      // state. The tools tab toggle gate can now enable the tool
      // without re-opening the settings sheet.
      expect(settings.googleSheetConfig.isFullyConfigured, isTrue);
      expect(settings.googleSheetConfig.spreadsheetId, 'ss-id');
      expect(settings.googleSheetConfig.defaultTab, 'Sheet1');
      expect(settings.googleSheetConfig.authedEmail, 'me@x.com');
    },
  );

  test('toggle gate decision is consistent across the lifetime of the app: '
      '`isFullyConfigured` reflects the persisted state right after '
      'construction and right after every service notify', () async {
    // Right after construction: fresh install.
    expect(settings.googleSheetConfig.isFullyConfigured, isFalse);

    // After a full save flow.
    await sharedSheets.updateSelection(
      spreadsheetId: 'ss-id',
      defaultTab: 'Sheet1',
    );
    await storage.saveGoogleSheetConfig(
      sharedSheets.config.copyWith(
        accessToken: 'tok',
        refreshToken: 'ref',
        tokenExpiresAtMs: 9999999999999,
      ),
    );
    await sharedSheets.load();
    expect(settings.googleSheetConfig.isFullyConfigured, isTrue);

    // After sign-out (clears tokens but keeps spreadsheetId).
    await sharedSheets.signOut();
    expect(settings.googleSheetConfig.isFullyConfigured, isFalse);
    // spreadsheetId survives signOut — only the tokens are wiped.
    expect(settings.googleSheetConfig.spreadsheetId, 'ss-id');
  });

  test('fresh SettingsProvider constructed after a save (e.g. Hot Restart) '
      'sees the persisted config — this is the "saved config survives '
      'restart" guarantee', () async {
    await sharedSheets.updateSelection(
      spreadsheetId: 'ss-id',
      defaultTab: 'Sheet1',
    );
    await storage.saveGoogleSheetConfig(
      sharedSheets.config.copyWith(
        accessToken: 'tok',
        refreshToken: 'ref',
        tokenExpiresAtMs: 9999999999999,
      ),
    );

    // Simulate a hot restart: brand new SettingsProvider + a
    // service re-load from the same SharedPreferences. Both
    // must see the saved config.
    final freshSheets = GoogleSheetsService(
      storage: storage,
      httpClient: _StubClient(),
      credentialsLoader: () async => _creds,
    );
    await freshSheets.load();
    final freshSettings = SettingsProvider(storage, freshSheets);
    await freshSettings.load();

    expect(freshSettings.googleSheetConfig.isFullyConfigured, isTrue);
    expect(freshSettings.googleSheetConfig.spreadsheetId, 'ss-id');
    expect(freshSettings.googleSheetConfig.defaultTab, 'Sheet1');
    expect(freshSettings.googleSheetConfig.accessToken, 'tok');
  });
}

class _StubClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([utf8Bytes]),
      200,
    );
  }
}

List<int> get utf8Bytes => '{}'.codeUnits;
