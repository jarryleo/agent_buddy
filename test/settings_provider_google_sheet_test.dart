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
