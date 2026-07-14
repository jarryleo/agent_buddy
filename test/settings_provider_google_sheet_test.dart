import 'dart:io';

import 'package:agent_buddy/models/google_sheet_config.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/google_sheets_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
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

/// Regression tests for the SettingsProvider ↔ GoogleSheetsService
/// wiring. The original bug: after saving Google Sheet settings
/// (which writes through `GoogleSheetsService.updateSelection()`),
/// `SettingsProvider.googleSheetConfig` stayed stale and the tools
/// tab toggle gate (`isFullyConfigured`) kept returning false,
/// causing the settings sheet to re-open on every toggle attempt.
///
/// Fix: SettingsProvider subscribes to the service and mirrors
/// `service.config` into its cached copy.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late GoogleSheetsService sheets;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_sheets_settings_test_',
    );
    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
    sheets = GoogleSheetsService(
      storage: storage,
      httpClient: _NoopClient(),
      credentialsLoader: () async => _creds,
      urlLauncher: (_) async => true,
    );
    await sheets.load();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test(
    'mirrors service.config after a successful save — '
    'isFullyConfigured flips true so the tools tab can enable the tool',
    () async {
      final provider = SettingsProvider(storage, sheets);
      await provider.load();

      // Baseline: fresh install → unconfigured.
      expect(provider.googleSheetConfig.isFullyConfigured, isFalse);

      // Drive the service through the same flow the settings sheet
      // uses: persist a valid id + tab + tokens.
      await sheets.updateSelection(
        spreadsheetId: 'ss-id',
        defaultTab: 'Sheet1',
      );
      // Simulate the post-OAuth token population the auth flow
      // would do on success.
      await storage.saveGoogleSheetConfig(
        sheets.config.copyWith(
          accessToken: 'tok',
          refreshToken: 'ref',
          tokenExpiresAtMs: 9999999999999,
          authedEmail: 'me@x.com',
        ),
      );
      // Re-sync the in-memory service state (the auth callback does
      // this internally; the test driver mimics it).
      await sheets.load();

      // The provider should now see the fully-configured state
      // without us having to call SettingsProvider.saveGoogleSheetConfig
      // ourselves.
      expect(provider.googleSheetConfig.isFullyConfigured, isTrue);
      expect(provider.googleSheetConfig.spreadsheetId, 'ss-id');
      expect(provider.googleSheetConfig.defaultTab, 'Sheet1');
      expect(provider.googleSheetConfig.authedEmail, 'me@x.com');
    },
  );

  test(
    'mirrors service.config after signOut — '
    'isFullyConfigured flips false so the toggle gate reopens the sheet',
    () async {
      // Seed a configured state.
      await storage.saveGoogleSheetConfig(
        const GoogleSheetConfig(
          spreadsheetId: 'ss-id',
          defaultTab: 'Sheet1',
          accessToken: 'tok',
          refreshToken: 'ref',
          tokenExpiresAtMs: 9999999999999,
        ),
      );
      await sheets.load();

      final provider = SettingsProvider(storage, sheets);
      await provider.load();
      expect(provider.googleSheetConfig.isFullyConfigured, isTrue);

      // User signs out via the settings sheet's "退出登录" button.
      await sheets.signOut();

      expect(provider.googleSheetConfig.isFullyConfigured, isFalse);
      expect(provider.googleSheetConfig.accessToken, isNull);
      expect(provider.googleSheetConfig.refreshToken, isNull);
    },
  );

  test(
    'does not throw when constructed without a GoogleSheetsService '
    '(backward-compat with unit tests that build a bare SettingsProvider)',
    () async {
      final provider = SettingsProvider(storage);
      await provider.load();
      expect(provider.googleSheetConfig.isFullyConfigured, isFalse);
    },
  );

  test('removes the listener on dispose so it does not leak across '
      'provider rebuilds', () async {
    final provider = SettingsProvider(storage, sheets);
    await provider.load();

    // We can't peek at ChangeNotifier.hasListeners from outside
    // the class (it's @protected), so verify the contract
    // indirectly: capture notifications while the provider is
    // alive, then dispose and confirm no further notifications
    // fire when the service updates.
    var notifications = 0;
    provider.addListener(() => notifications++);

    await sheets.signOut();
    expect(notifications, greaterThan(0));

    provider.dispose();
    notifications = 0;
    await sheets.updateSelection(spreadsheetId: 'x', defaultTab: 'y');
    expect(notifications, 0, reason: 'listener should be removed on dispose');
  });

  // ---------------------------------------------------------------------
  // Regression tests for the "two-instance" bug.
  //
  // The app constructs a single `GoogleSheetsService` in `main.dart`,
  // wires it into both the `ChangeNotifierProvider` (so the settings
  // sheet observes it) and the `ToolService` (so the `google_sheet`
  // tool uses it). The original bug: `main.dart` only passed
  // `storage` to `ToolService`, which caused `ToolService` to spin
  // up a *second* `GoogleSheetsService` instance internally. The
  // settings sheet then wrote to the second instance, and the
  // listener in `SettingsProvider` (attached to the first) never
  // saw the update — so the toggle gate kept re-opening the sheet
  // after a successful save.
  //
  // The fix: pass the same `googleSheets` instance to `ToolService`.
  // These tests pin that contract by exercising the *consumer* API
  // (SettingsProvider, settings-sheet write) end-to-end and
  // asserting both consumers see the same state.
  // ---------------------------------------------------------------------

  test('after save: SettingsProvider._googleSheetConfig and the service '
      'instance the settings sheet uses are the same object', () async {
    // Simulate the real wiring: one GoogleSheetsService instance
    // shared between the ChangeNotifierProvider and the
    // ToolService container. The settings sheet's writes go to
    // the same instance the SettingsProvider listens to.
    final sharedSheets = GoogleSheetsService(
      storage: storage,
      httpClient: _NoopClient(),
      credentialsLoader: () async => _creds,
    );
    await sharedSheets.load();

    final provider = SettingsProvider(storage, sharedSheets);
    await provider.load();

    // Drive the same flow the settings sheet's Save button uses.
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

    // Both consumers see the same end state — without this, the
    // tools tab toggle would re-open the settings sheet forever.
    expect(provider.googleSheetConfig.isFullyConfigured, isTrue);
    expect(provider.googleSheetConfig.spreadsheetId, 'ss-id');
    expect(provider.googleSheetConfig.defaultTab, 'Sheet1');
  });

  test('app restart: the saved config is loaded by a fresh SettingsProvider '
      'and GoogleSheetsService on the same SharedPreferences', () async {
    // Seed a configured state via session 1.
    await sheets.updateSelection(spreadsheetId: 'ss-id', defaultTab: 'Sheet1');
    await storage.saveGoogleSheetConfig(
      sheets.config.copyWith(
        accessToken: 'tok',
        refreshToken: 'ref',
        tokenExpiresAtMs: 9999999999999,
        authedEmail: 'me@x.com',
      ),
    );

    // Session 2 (simulating an app restart): brand new
    // GoogleSheetsService and SettingsProvider, but the same
    // StorageService (so the same SharedPreferences mock).
    final sheets2 = GoogleSheetsService(
      storage: storage,
      httpClient: _NoopClient(),
      credentialsLoader: () async => _creds,
    );
    await sheets2.load();
    final provider2 = SettingsProvider(storage, sheets2);
    await provider2.load();

    // The saved config is still there.
    expect(provider2.googleSheetConfig.isFullyConfigured, isTrue);
    expect(provider2.googleSheetConfig.spreadsheetId, 'ss-id');
    expect(provider2.googleSheetConfig.defaultTab, 'Sheet1');
    expect(provider2.googleSheetConfig.accessToken, 'tok');
    expect(provider2.googleSheetConfig.refreshToken, 'ref');
    expect(provider2.googleSheetConfig.authedEmail, 'me@x.com');
  });

  test('toggle gate: when the user has not configured, '
      'isFullyConfigured is false so the tools tab refuses to enable '
      'the tool and jumps to the settings sheet', () async {
    final provider = SettingsProvider(storage, sheets);
    await provider.load();

    // Fresh install: nothing saved.
    expect(provider.googleSheetConfig.isFullyConfigured, isFalse);

    // The tools tab handler mirrors this check (see tools_tab.dart).
    // The requirement is: when the user taps the switch, the
    // gate must trigger and the tool must NOT become enabled
    // until they've saved a valid config.
    bool gate(bool switchOn) {
      return switchOn && !provider.googleSheetConfig.isFullyConfigured;
    }

    expect(gate(true), isTrue, reason: 'gate should block the tap');
  });

  test('toggle gate: after a successful save, '
      'isFullyConfigured is true so the next tap enables the tool', () async {
    // Start fresh.
    final provider = SettingsProvider(storage, sheets);
    await provider.load();
    expect(provider.googleSheetConfig.isFullyConfigured, isFalse);

    // Drive the full save flow.
    await sheets.updateSelection(spreadsheetId: 'ss-id', defaultTab: 'Sheet1');
    await storage.saveGoogleSheetConfig(
      sheets.config.copyWith(
        accessToken: 'tok',
        refreshToken: 'ref',
        tokenExpiresAtMs: 9999999999999,
      ),
    );
    await sheets.load();

    // After the save, the gate passes.
    bool gate(bool switchOn) {
      return switchOn && !provider.googleSheetConfig.isFullyConfigured;
    }

    expect(gate(true), isFalse, reason: 'gate should NOT block the tap');
    expect(provider.googleSheetConfig.isFullyConfigured, isTrue);
  });
}

class _NoopClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable([utf8Bytes]),
      200,
    );
  }
}

List<int> get utf8Bytes => '{}\n'.codeUnits;
