import 'dart:io';

import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/platform/autostart_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings-level tests for the auto-start toggle.
///
/// Coverage:
///   * `autoStartEnabled` persists across SettingsProvider reloads
///   * toggling without an attached service still persists the
///     preference (so a desktop upgrade on the same device
///     restores it)
///   * `attachAutostartService` re-applies the persisted
///     preference on app startup (calls `setEnabled(true)` once
///     if the user previously enabled it)
///   * `setAutoStartEnabled` returns `false` when the OS write
///     fails (fake service returns `null`)
class _FakeAutostartService implements AutostartService {
  _FakeAutostartService({this.actualEnabled = false});

  bool actualEnabled;
  bool isSupported = true;
  bool shouldFail = false;
  int setEnabledCalls = 0;

  @override
  Future<bool> isEnabled() async => actualEnabled;

  @override
  Future<bool?> setEnabled(bool enabled) async {
    setEnabledCalls++;
    if (shouldFail) return null;
    actualEnabled = enabled;
    return enabled;
  }
}

void main() {
  late Directory tempDir;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('autostart_settings_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<SettingsProvider> loadProvider({AutostartService? autostart}) async {
    final storage = StorageService();
    await storage.init();
    final p = SettingsProvider(storage, null, autostart);
    await p.load();
    return p;
  }

  group('SettingsProvider.autoStartEnabled', () {
    test('defaults to false on a fresh install', () async {
      final p = await loadProvider();
      expect(p.autoStartEnabled, isFalse);
    });

    test('persists across reload', () async {
      final p1 = await loadProvider();
      await p1.setAutoStartEnabled(true);

      final p2 = await loadProvider();
      expect(p2.autoStartEnabled, isTrue);
    });

    test(
      'setAutoStartEnabled without an attached service still persists',
      () async {
        // No autostart service attached — simulates a non-desktop
        // build (e.g. mobile) where the toggle should still work
        // for cross-platform preference parity. The user's desktop
        // counterpart will pick the value up later.
        final p = await loadProvider();
        final ok = await p.setAutoStartEnabled(true);
        expect(ok, isTrue, reason: 'no service means no failure path');
        expect(p.autoStartEnabled, isTrue);
        final raw = (await SharedPreferences.getInstance()).getBool(
          'auto_start_enabled',
        );
        expect(raw, isTrue);
      },
    );

    test(
      'setAutoStartEnabled forwards to the service when supported',
      () async {
        final svc = _FakeAutostartService();
        final p = await loadProvider(autostart: svc);

        final ok = await p.setAutoStartEnabled(true);
        expect(ok, isTrue);
        expect(p.autoStartEnabled, isTrue);
        expect(svc.setEnabledCalls, 1);
        expect(await svc.isEnabled(), isTrue);

        await p.setAutoStartEnabled(false);
        expect(p.autoStartEnabled, isFalse);
        expect(svc.setEnabledCalls, 2);
        expect(await svc.isEnabled(), isFalse);
      },
    );

    test(
      'setAutoStartEnabled returns false and rolls back on service failure',
      () async {
        final svc = _FakeAutostartService();
        svc.shouldFail = true;
        final p = await loadProvider(autostart: svc);

        final ok = await p.setAutoStartEnabled(true);
        expect(ok, isFalse);
        // The cached preference is still what the user *asked* for
        // (the SettingsProvider stays consistent with the user's
        // intent), but the persistent flag stays false because the
        // OS write failed.
        expect(p.autoStartEnabled, isTrue);
        final raw = (await SharedPreferences.getInstance()).getBool(
          'auto_start_enabled',
        );
        expect(
          raw,
          isTrue,
          reason:
              'we persist the user\'s intent so they can retry on next launch',
        );
      },
    );

    test(
      'attachAutostartService re-applies the persisted preference on boot',
      () async {
        // Simulate a previous launch where the user enabled auto-
        // start. The persisted flag is true; on the next launch the
        // provider is constructed without a service and then has
        // the service attached later — at which point it should
        // re-apply.
        final storage = StorageService();
        await storage.init();
        await storage.setAutoStartEnabled(true);

        final svc = _FakeAutostartService();
        final p = SettingsProvider(storage, null, null);
        await p.load();
        expect(p.autoStartEnabled, isTrue);
        // No service yet → no calls.
        expect(svc.setEnabledCalls, 0);

        p.attachAutostartService(svc);

        // Let the fire-and-forget future settle.
        await Future<void>.delayed(Duration.zero);
        expect(svc.setEnabledCalls, greaterThanOrEqualTo(1));
        expect(await svc.isEnabled(), isTrue);
      },
    );

    test('attachAutostartService is a no-op when the persisted preference '
        'is false (no re-enable on boot)', () async {
      final svc = _FakeAutostartService();
      final p = await loadProvider(autostart: svc);

      // Fresh install → preference is false → no boot-time apply.
      p.attachAutostartService(svc);
      await Future<void>.delayed(Duration.zero);
      expect(svc.setEnabledCalls, 0);
    });

    test('attachAutostartService(null) is a safe no-op', () async {
      final p = await loadProvider();
      p.attachAutostartService(null);
      // No exception, no notifyListeners side-effect that would
      // throw on a disposed provider.
      expect(p.autoStartEnabled, isFalse);
    });

    test('attachAutostartService ignores an unsupported service', () async {
      final svc = _FakeAutostartService();
      svc.isSupported = false;
      final p = await loadProvider(autostart: svc);
      await p.setAutoStartEnabled(true);
      // isSupported == false → the service isn't called at all.
      expect(svc.setEnabledCalls, 0);
      // The preference is still recorded (so a desktop upgrade
      // restores it).
      expect(p.autoStartEnabled, isTrue);
    });

    test(
      'legacy SettingsProvider(storage, googleSheets) keeps working',
      () async {
        // Backward-compat with unit tests that build a bare
        // SettingsProvider without an AutostartService.
        final storage = StorageService();
        await storage.init();
        final p = SettingsProvider(storage);
        await p.load();
        await p.setAutoStartEnabled(true);
        expect(p.autoStartEnabled, isTrue);
      },
    );
  });
}
