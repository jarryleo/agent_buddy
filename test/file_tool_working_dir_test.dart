import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/models/picked_file.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/platform/file_service.dart';
import 'package:agent_buddy/services/platform/file_service_impl.dart'
    show FileServiceError, FileServiceImpl;
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/file_tool.dart';
import 'package:agent_buddy/services/tools/tool_base.dart';
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

  group('mobile branch via injected FileService', () {
    setUp(() {
      // Force the file tool into the mobile branch even on the
      // Linux test host so we can exercise pick / app:// / etc.
      overridePlatform(isMobileValue: true, isDesktopValue: false);
    });
    tearDown(resetPlatformOverrides);

    test(
      'pick surfaces a soft {cancelled:true} payload, not a ToolException',
      () async {
        final fake = _FakeFileService();
        fake.pickResult = null; // null == cancelled
        final toolService = ToolService(fileBuilder: () => fake);
        addTearDown(toolService.dispose);

        final tool = FileTool();
        final raw = await tool.execute({'action': 'pick'}, toolService);
        final envelope = jsonDecode(raw) as Map<String, dynamic>;
        expect(envelope['cancelled'], true);
        expect(envelope['ok'], false);
      },
    );

    test(
      'pick success returns the picked file with a picker:// path',
      () async {
        final fake = _FakeFileService();
        fake.pickResult = PickedFile(
          id: 'f-1',
          name: 'note.txt',
          size: 5,
          mimeType: 'text/plain',
          path: 'picker://f-1',
        );
        final toolService = ToolService(fileBuilder: () => fake);
        addTearDown(toolService.dispose);

        final tool = FileTool();
        final raw = await tool.execute({'action': 'pick'}, toolService);
        final envelope = jsonDecode(raw) as Map<String, dynamic>;
        expect(envelope['ok'], true);
        expect(envelope['cancelled'], false);
        final items = envelope['items'] as List;
        expect(items, hasLength(1));
        final first = (items.first as Map).cast<String, dynamic>();
        expect(first['id'], 'f-1');
        expect(first['path'], 'picker://f-1');
      },
    );

    test('read on app://documents goes through the FileService', () async {
      final fake = _FakeFileService();
      fake.readResult = 'hello world'.codeUnits;
      final toolService = ToolService(fileBuilder: () => fake);

      final tool = FileTool();
      final raw = await tool.execute({
        'action': 'read',
        'path': 'app://documents/hello.txt',
      }, toolService);
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      expect(envelope['action'], 'read');
      expect(envelope['path'], 'app://documents/hello.txt');
      expect(envelope['content'], 'hello world');
      expect(fake.lastReadPath, 'app://documents/hello.txt');
    });

    test('write on a picker://<id> delegates to the bridge', () async {
      final fake = _FakeFileService();
      final toolService = ToolService(fileBuilder: () => fake);
      final tool = FileTool();
      final raw = await tool.execute({
        'action': 'write',
        'path': 'picker://f-1',
        'content': 'payload',
      }, toolService);
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      expect(envelope['ok'], true);
      expect(fake.lastWriteId, 'f-1');
      expect(String.fromCharCodes(fake.lastWriteBytes!), 'payload');
    });

    test('delete refuses picker://<id> with a friendly error', () async {
      final fake = _FakeFileService();
      final toolService = ToolService(fileBuilder: () => fake);
      final tool = FileTool();
      try {
        await tool.execute({
          'action': 'delete',
          'path': 'picker://f-1',
        }, toolService);
        fail('expected ToolException');
      } on Object catch (e) {
        expect(e.toString(), contains('release'));
      }
      expect(fake.deleteCalls, 0);
    });

    test('list_dir refuses picker://<id> with a friendly error', () async {
      final fake = _FakeFileService();
      final toolService = ToolService(fileBuilder: () => fake);
      final tool = FileTool();
      try {
        await tool.execute({
          'action': 'list_dir',
          'path': 'picker://f-1',
        }, toolService);
        fail('expected ToolException');
      } on Object catch (e) {
        expect(e.toString(), contains('parent directory'));
      }
    });

    test('release(id) drops the bridge handle', () async {
      final fake = _FakeFileService();
      final toolService = ToolService(fileBuilder: () => fake);
      final tool = FileTool();
      final raw = await tool.execute({
        'action': 'release',
        'id': 'f-1',
      }, toolService);
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      expect(envelope['ok'], true);
      expect(fake.lastReleasedId, 'f-1');
    });

    test('schema includes mobile-only actions (pick / release)', () {
      final tool = FileTool();
      final schema = tool.buildSchema();
      final actions =
          ((schema['function']!['parameters']!['properties']
                      as Map)['action']!['enum']
                  as List)
              .cast<String>();
      expect(actions, contains('pick'));
      expect(actions, contains('release'));
    });
  });

  group('mobile branch with a configured working directory', () {
    setUp(() {
      overridePlatform(isMobileValue: true, isDesktopValue: false);
    });
    tearDown(resetPlatformOverrides);

    /// Builds a [ToolService] whose `FileService` is a real
    /// `FileServiceImpl` (not the platform-default stub the
    /// factory returns on Linux) and whose `workingDirectory`
    /// lookup reads the latest value from [storage].
    ToolService buildToolService() {
      return ToolService(
        storage: storage,
        fileBuilder: () => FileServiceImpl(
          workingDirectoryLookup: () => storage.modelWorkingDirectory,
        ),
      );
    }

    test('relative paths read against the working directory', () async {
      // Seed a file inside the working dir that the model can
      // pick up with a bare relative path.
      final seed = File(p.join(workingDir.path, 'seed.txt'));
      seed.writeAsStringSync('hello world');

      await storage.setModelWorkingDirectory(workingDir.path);
      final toolService = buildToolService();
      addTearDown(toolService.dispose);

      final tool = FileTool();
      final raw = await tool.execute({
        'action': 'read',
        'path': 'seed.txt',
      }, toolService);
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      expect(envelope['encoding'], 'utf-8');
      expect(envelope['content'], 'hello world');
    });

    test('write a relative path lands inside the working directory', () async {
      await storage.setModelWorkingDirectory(workingDir.path);
      final toolService = buildToolService();
      addTearDown(toolService.dispose);

      final tool = FileTool();
      final raw = await tool.execute({
        'action': 'write',
        'path': 'working://sub/dir/created.txt',
        'content': 'created',
      }, toolService);
      expect(raw, contains('"ok":true'));
      final written = File(p.join(workingDir.path, 'sub/dir/created.txt'));
      expect(written.existsSync(), isTrue);
      expect(written.readAsStringSync(), 'created');
    });

    test('list_dir on the working dir root lists the children', () async {
      File(p.join(workingDir.path, 'a.txt')).writeAsStringSync('a');
      Directory(p.join(workingDir.path, 'nested')).createSync();
      File(p.join(workingDir.path, 'nested/b.txt')).writeAsStringSync('b');

      await storage.setModelWorkingDirectory(workingDir.path);
      final toolService = buildToolService();
      addTearDown(toolService.dispose);

      final tool = FileTool();
      final raw = await tool.execute({
        'action': 'list_dir',
        'path': 'working://',
      }, toolService);
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      final names = (envelope['entries'] as List)
          .map((e) => (e as Map)['name'])
          .toSet();
      expect(names, containsAll(['a.txt', 'nested']));
      // Paths are surfaced as `working://...` so the model can
      // re-use them on follow-up turns.
      final a =
          (envelope['entries'] as List).firstWhere(
                (e) => (e as Map)['name'] == 'a.txt',
              )
              as Map;
      expect(a['path'], 'working://a.txt');
    });

    test(
      'list_dir on a working://sub/ returns working://sub/<name> children',
      () async {
        Directory(p.join(workingDir.path, 'sub')).createSync();
        File(
          p.join(workingDir.path, 'sub/inner.txt'),
        ).writeAsStringSync('inner');

        await storage.setModelWorkingDirectory(workingDir.path);
        final toolService = buildToolService();
        addTearDown(toolService.dispose);

        final tool = FileTool();
        final raw = await tool.execute({
          'action': 'list_dir',
          'path': 'working://sub',
        }, toolService);
        final envelope = jsonDecode(raw) as Map<String, dynamic>;
        final entries = envelope['entries'] as List;
        expect(entries, hasLength(1));
        final first = entries.first as Map;
        expect(first['name'], 'inner.txt');
        expect(first['path'], 'working://sub/inner.txt');
      },
    );

    test('relative path without a working dir returns a clear error', () async {
      // No setModelWorkingDirectory — the user hasn't picked a
      // folder. The mobile file tool should refuse bare
      // relative paths with a helpful message.
      final toolService = buildToolService();
      addTearDown(toolService.dispose);

      final tool = FileTool();
      try {
        await tool.execute({'action': 'read', 'path': 'seed.txt'}, toolService);
        fail('expected ToolException');
      } on Object catch (e) {
        expect(e.toString(), contains('no working directory'));
      }
    });

    test('..-escape on the working dir is rejected', () async {
      await storage.setModelWorkingDirectory(workingDir.path);
      final toolService = buildToolService();
      addTearDown(toolService.dispose);

      final tool = FileTool();
      try {
        await tool.execute({
          'action': 'read',
          'path': '../outside.txt',
        }, toolService);
        fail('expected ToolException');
      } on Object catch (e) {
        expect(e.toString(), contains('escapes'));
      }
    });

    test('absolute path on mobile is rejected (no raw OS paths)', () async {
      await storage.setModelWorkingDirectory(workingDir.path);
      final toolService = buildToolService();
      addTearDown(toolService.dispose);

      final tool = FileTool();
      try {
        await tool.execute({
          'action': 'read',
          'path': p.join(outsideDir.path, 'abs.txt'),
        }, toolService);
        fail('expected ToolException');
      } on Object catch (e) {
        expect(e.toString(), contains('invalid path'));
      }
    });

    test('schema description mentions the working directory on mobile', () {
      final tool = FileTool();
      final schema = tool.buildSchema();
      final pathDesc =
          ((schema['function']!['parameters']!['properties']
                  as Map)['path']!['description']
              as String);
      expect(pathDesc, contains('working://'));
      expect(pathDesc, contains('相对路径'));
    });
  });
}

class _FakeFileService implements FileService {
  PickedFile? pickResult = PickedFile(
    id: 'f-1',
    name: 'note.txt',
    size: 5,
    mimeType: 'text/plain',
    path: 'picker://f-1',
  );
  List<int>? readResult = const [];
  String? lastReadPath;
  int readCalls = 0;
  int pickCalls = 0;
  int deleteCalls = 0;
  String? lastWriteId;
  List<int>? lastWriteBytes;
  String? lastReleasedId;
  String? workingDir;

  @override
  String? get workingDirectory => workingDir;

  @override
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false}) async {
    pickCalls++;
    return pickResult;
  }

  @override
  Future<void> release(String id) async {
    lastReleasedId = id;
  }

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    readCalls++;
    lastReadPath = path;
    return readResult ?? const [];
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool append = false,
  }) async {
    if (isPickerPath(path)) {
      lastWriteId = pickerIdOf(path);
      lastWriteBytes = bytes;
      return;
    }
    throw FileServiceError('not exercised in this test');
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    deleteCalls++;
    if (isPickerPath(path)) {
      throw const FileServiceError(
        'delete is not allowed on picker://<id> paths; '
        'use release(id) to drop the local handle instead',
      );
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    throw FileServiceError('not exercised in this test');
  }

  @override
  Future<List<FileEntry>> listDir(String path, {bool recursive = false}) async {
    return const [];
  }

  @override
  Future<FileAttrs> readAttr(String path) async {
    return FileAttrs(
      path: path,
      type: 'file',
      size: 0,
      modifiedMs: 0,
      accessedMs: 0,
      changedMs: 0,
      isDirectory: false,
      isFile: true,
      isLink: false,
    );
  }
}

// Suppress an unused-import lint when the analyzer walks the
// test in isolation (we use jsonDecode in the production code
// path but not in this test file).
// ignore: unused_element
void _keepImports() {
  jsonDecode;
}
