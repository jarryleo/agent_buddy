import 'dart:async';
import 'dart:io';

import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/google_sheets_service.dart';
import 'package:agent_buddy/services/pet_window_controller.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings-level tests for the desktop pet toggle / active pet id.
///
/// Coverage:
///   * `showDesktopPet` persists across SettingsProvider reloads
///   * `setShowDesktopPet(true, activePetId: <id>)` records both
///     the master toggle and the active pick
///   * `setActivePetId(null)` clears the persisted selection
void main() {
  late Directory tempDir;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('pet_settings_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<SettingsProvider> buildProvider() async {
    final storage = StorageService();
    await storage.init();
    final provider = SettingsProvider(
      storage,
      GoogleSheetsService(storage: storage),
    );
    await provider.load();
    return provider;
  }

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(condition(), isTrue);
  }

  test('showDesktopPet defaults to false on a fresh install', () async {
    final provider = await buildProvider();
    expect(provider.showDesktopPet, isFalse);
    expect(provider.activePetId, isNull);
  });

  test('setShowDesktopPet persists across reloads', () async {
    final provider = await buildProvider();
    await provider.setShowDesktopPet(true);
    expect(provider.showDesktopPet, isTrue);

    final reload = await buildProvider();
    expect(reload.showDesktopPet, isTrue);
  });

  test('setShowDesktopPet(activePetId:) records the active pick', () async {
    final provider = await buildProvider();
    await provider.setShowDesktopPet(true, activePetId: 'builtin:anya');
    expect(provider.showDesktopPet, isTrue);
    expect(provider.activePetId, 'builtin:anya');

    final reload = await buildProvider();
    expect(reload.showDesktopPet, isTrue);
    expect(reload.activePetId, 'builtin:anya');
  });

  test('setActivePetId(null) clears the persisted selection', () async {
    final provider = await buildProvider();
    await provider.setActivePetId('builtin:anya');
    expect(provider.activePetId, 'builtin:anya');

    await provider.setActivePetId(null);
    expect(provider.activePetId, isNull);

    final reload = await buildProvider();
    expect(reload.activePetId, isNull);
  });

  test('tray toggle hides and reuses the existing pet window', () async {
    final provider = await buildProvider();
    final windowsChanged = StreamController<void>.broadcast(sync: true);
    var spawnCalls = 0;
    var hideCalls = 0;
    var showCalls = 0;
    var closeCalls = 0;
    final controller = PetWindowController(
      settings: provider,
      spawnWindow: (petId) async {
        spawnCalls++;
        return WindowController.fromWindowId('pet-window');
      },
      hideWindow: (_) async {
        hideCalls++;
      },
      showWindow: (_) async {
        showCalls++;
      },
      closeWindow: (_) async {
        closeCalls++;
        windowsChanged.add(null);
      },
      listWindows: () async => const [],
      windowsChanged: windowsChanged.stream,
    );
    addTearDown(() async {
      await controller.dispose();
      await windowsChanged.close();
    });

    await provider.setShowDesktopPet(true);
    await waitFor(() => spawnCalls == 1);

    await provider.setShowDesktopPet(false);
    await waitFor(() => hideCalls == 1);

    await provider.setShowDesktopPet(true);
    await waitFor(() => showCalls == 1);

    expect(spawnCalls, 1);
    expect(closeCalls, 0);
  });

  test('petAiBehaviorEnabled defaults to false on a fresh install', () async {
    final provider = await buildProvider();
    expect(provider.petAiBehaviorEnabled, isFalse);
  });

  test('setPetAiBehaviorEnabled persists across reloads', () async {
    final provider = await buildProvider();
    await provider.setPetAiBehaviorEnabled(true);
    expect(provider.petAiBehaviorEnabled, isTrue);

    final reload = await buildProvider();
    expect(reload.petAiBehaviorEnabled, isTrue);
  });

  test(
    'setPetAiBehaviorEnabled(false) clears the persisted preference',
    () async {
      final provider = await buildProvider();
      await provider.setPetAiBehaviorEnabled(true);
      await provider.setPetAiBehaviorEnabled(false);
      expect(provider.petAiBehaviorEnabled, isFalse);

      final reload = await buildProvider();
      expect(reload.petAiBehaviorEnabled, isFalse);
    },
  );
}
