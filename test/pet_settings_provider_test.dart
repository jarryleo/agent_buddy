import 'dart:io';

import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/google_sheets_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
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
    final provider = SettingsProvider(storage, GoogleSheetsService(storage: storage));
    await provider.load();
    return provider;
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
}