import 'dart:io';

import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/file_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late Directory workingDir;
  late Directory outsideDir;
  late StorageService storage;

  setUpAll(ChatSessionRepository.registerAdapters);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('file_tool_working_');
    Hive.init(tempDir.path);
    workingDir = await tempDir.createTemp('working_');
    outsideDir = await tempDir.createTemp('outside_');
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test('relative paths resolve to the configured working directory', () async {
    await storage.setModelWorkingDirectory(workingDir.path);
    final toolService = ToolService(storage: storage);
    addTearDown(toolService.dispose);

    final tool = FileTool();
    final out = await tool.execute({
      'action': 'write',
      'path': 'hi.txt',
      'content': 'hello',
    }, toolService);
    expect(out, contains('"ok":true'));
    final written = File(p.join(workingDir.path, 'hi.txt'));
    expect(written.existsSync(), isTrue);
  });

  test('absolute paths bypass the working directory', () async {
    await storage.setModelWorkingDirectory(workingDir.path);
    final toolService = ToolService(storage: storage);
    addTearDown(toolService.dispose);

    final tool = FileTool();
    final absolute = p.join(outsideDir.path, 'abs.txt');
    final out = await tool.execute({
      'action': 'write',
      'path': absolute,
      'content': 'data',
    }, toolService);
    expect(out, contains('"ok":true'));
    expect(File(absolute).existsSync(), isTrue);
  });
}
