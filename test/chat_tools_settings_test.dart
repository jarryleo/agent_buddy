import 'dart:io';

import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late StorageService storage;

  setUpAll(ChatSessionRepository.registerAdapters);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('chat_tools_settings_');
    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await storage.sessions.close();
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test('working directory and thinking mode persist', () async {
    final settings = SettingsProvider(storage);
    await settings.load();
    await settings.setModelWorkingDirectory('C:/workspace/project');
    await settings.setThinkingModeEnabled(true);

    final restored = SettingsProvider(storage);
    await restored.load();

    expect(restored.modelWorkingDirectory, 'C:/workspace/project');
    expect(restored.thinkingModeEnabled, isTrue);
    expect(
      ToolService(storage: storage).workingDirectory,
      'C:/workspace/project',
    );

    final toolService = ToolService(storage: storage);
    addTearDown(toolService.dispose);
  });
}
