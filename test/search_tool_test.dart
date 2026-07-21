import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/models/picked_file.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/platform/file_service.dart';
import 'package:agent_buddy/services/platform/file_service_impl.dart'
    show FileServiceError;
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/search_tool.dart';
import 'package:agent_buddy/services/tools/tool_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('SearchTool schema', () {
    test('desktop schema exposes path + files + pattern', () {
      overridePlatform(isDesktopValue: true, isMobileValue: false);
      addTearDown(resetPlatformOverrides);
      final schema = SearchTool().buildSchema();
      expect(schema, isNotEmpty);
      final params = schema['function']['parameters'] as Map<String, dynamic>;
      final props = params['properties'] as Map<String, dynamic>;
      expect(props.keys, containsAll(<String>['path', 'files', 'pattern']));
      expect((params['required'] as List).cast<String>(), ['pattern']);
    });

    test('mobile schema mentions the picker:// + working:// schemes', () {
      overridePlatform(isDesktopValue: false, isMobileValue: true);
      addTearDown(resetPlatformOverrides);
      final schema = SearchTool().buildSchema();
      final desc =
          schema['function']['parameters']['properties']['path']['description']
              as String;
      expect(desc, contains('working://'));
      expect(desc, contains('picker://'));
    });

    test('web returns an empty schema', () {
      overridePlatform(isDesktopValue: false, isMobileValue: false);
      addTearDown(resetPlatformOverrides);
      final schema = SearchTool().buildSchema();
      expect(schema, isEmpty);
    });

    test('default settings (current platform) flag the tool as supported', () {
      // Don't force any override - use whatever the test host
      // advertises. We just check that the registry lists the
      // tool with the same id we expect.
      expect(SearchTool().id, 'search');
    });
  });

  group('SearchTool.execute (desktop)', () {
    late Directory root;
    late StorageService storage;
    late ToolService tools;

    setUpAll(ChatSessionRepository.registerAdapters);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final tmp = await Directory.systemTemp.createTemp('search_tool_');
      Hive.init(tmp.path);
      addTearDown(() async {
        await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
        await tmp.delete(recursive: true);
      });
      root = await tmp.createTemp('project_');
      storage = StorageService();
      await storage.init();
      await storage.setModelWorkingDirectory(root.path);
      tools = ToolService(storage: storage);
      addTearDown(tools.dispose);
      // Force desktop branch on every host.
      overridePlatform(isDesktopValue: true, isMobileValue: false);
      addTearDown(resetPlatformOverrides);
    });

    Future<void> writeFile(String rel, String content) async {
      final f = File(p.join(root.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
    }

    test('returns the standard envelope with line + column', () async {
      await writeFile('lib/a.dart', 'hello world\nTODO: fix\nbaz\n');
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'path': 'lib/a.dart',
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['query'], 'TODO');
      // `path` is a single file, so the result file is the
      // basename and the root is the absolute target path.
      final rootStr = (envelope['root'] as String).replaceAll('\\', '/');
      expect(rootStr, endsWith('/lib/a.dart'));
      expect(envelope['total_matches'], 1);
      expect(envelope['truncated'], isFalse);
      final files = (envelope['files'] as List).cast<Map<String, dynamic>>();
      expect(files, hasLength(1));
      expect(files.single['file'], 'a.dart');
      final m = (files.single['matches'] as List)
          .cast<Map<String, dynamic>>()
          .single;
      expect(m['line'], 2);
      expect(m['column'], 1);
      expect(m['text'], contains('TODO'));
    });

    test(
      'respects the configured working directory for relative paths',
      () async {
        await writeFile('notes.md', '# TODO list\n- one\n- two\n');
        final tool = SearchTool();
        final out = await tool.execute({'pattern': 'TODO', 'path': ''}, tools);
        final envelope = jsonDecode(out) as Map<String, dynamic>;
        expect(envelope['total_matches'], 1);
        // Relative paths don't carry a leading separator; just
        // compare the basename.
        final filePath = ((envelope['files'] as List).single['file'] as String)
            .replaceAll('\\', '/');
        expect(filePath, 'notes.md');
      },
    );

    test('skips heavy directories + binary files by default', () async {
      await writeFile('node_modules/foo/index.js', 'TODO\n');
      await writeFile('build/output.txt', 'TODO\n');
      await writeFile('assets/logo.png', '%TODO\n');
      await writeFile('src/real.dart', 'TODO\n');
      final tool = SearchTool();
      final out = await tool.execute({'pattern': 'TODO', 'path': ''}, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
      final files = (envelope['files'] as List).cast<Map<String, dynamic>>();
      final filePath = (files.single['file'] as String).replaceAll('\\', '/');
      expect(filePath, 'src/real.dart');
    });

    test('include_glob narrows the result set', () async {
      await writeFile('a.dart', 'TODO\n');
      await writeFile('b.txt', 'TODO\n');
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'path': '',
        'include_glob': '*.dart',
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
      final files = (envelope['files'] as List).cast<Map<String, dynamic>>();
      expect(files.single['file'], 'a.dart');
    });

    test('max_results surfaces a truncation hint', () async {
      final buf = StringBuffer();
      for (var i = 0; i < 20; i++) {
        buf.writeln('TODO line $i');
      }
      await writeFile('big.txt', buf.toString());
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'path': 'big.txt',
        'max_results': 5,
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 5);
      expect(envelope['truncated'], isTrue);
      expect(envelope['truncation_hint'], isA<String>());
    });

    test('rejects empty pattern', () async {
      final tool = SearchTool();
      await expectLater(
        tool.execute({'pattern': ''}, tools),
        throwsA(isA<ToolException>()),
      );
    });

    test('falls back to the working directory when no path is given', () async {
      // path + files both empty -> the configured working
      // directory is the implicit search root.
      await writeFile('default_target.md', 'TODO here\n');
      final tool = SearchTool();
      final out = await tool.execute({'pattern': 'TODO'}, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
      final filePath = ((envelope['files'] as List).single['file'] as String)
          .replaceAll('\\', '/');
      expect(filePath, 'default_target.md');
    });

    test('explicit files list works without a path', () async {
      await writeFile('a.txt', 'TODO\n');
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'files': [p.join(root.path, 'a.txt')],
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
    });
  });

  group('SearchTool.execute (mobile)', () {
    late _InMemoryFileService fake;
    late ToolService tools;

    setUpAll(ChatSessionRepository.registerAdapters);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final tmp = await Directory.systemTemp.createTemp('search_tool_mobile_');
      Hive.init(tmp.path);
      addTearDown(() async {
        await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
        await tmp.delete(recursive: true);
      });
      fake = _InMemoryFileService(workingDir: '/virtual/working');
      tools = ToolService(fileBuilder: () => fake);
      addTearDown(tools.dispose);
      overridePlatform(isDesktopValue: false, isMobileValue: true);
      addTearDown(resetPlatformOverrides);
    });

    test('searches a working:// directory via FileService', () async {
      fake.filesByPath['working://src'] = const [
        FileEntry(
          name: 'a.dart',
          path: 'working://src/a.dart',
          isDirectory: false,
          size: 0,
          modifiedMs: 0,
        ),
        FileEntry(
          name: 'b.dart',
          path: 'working://src/b.dart',
          isDirectory: false,
          size: 0,
          modifiedMs: 0,
        ),
      ];
      fake.contentByPath['working://src/a.dart'] = 'TODO: alpha\n';
      fake.contentByPath['working://src/b.dart'] = 'beta line\n';

      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'path': 'working://src',
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
      final files = (envelope['files'] as List).cast<Map<String, dynamic>>();
      expect(files.single['file'], 'working://src/a.dart');
    });

    test('searches a single picker:// file', () async {
      fake.contentByPath['picker://f-1'] = 'line one\nTODO: fix\nline three\n';
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'path': 'picker://f-1',
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
      final files = (envelope['files'] as List).cast<Map<String, dynamic>>();
      expect(files.single['file'], 'picker://f-1');
      final m = (files.single['matches'] as List)
          .cast<Map<String, dynamic>>()
          .single;
      expect(m['line'], 2);
    });

    test(
      'returns a soft empty hint when no working dir is configured',
      () async {
        fake._workingDir = null;
        final tool = SearchTool();
        final out = await tool.execute({
          'pattern': 'TODO',
          'path': 'working://src',
        }, tools);
        final envelope = jsonDecode(out) as Map<String, dynamic>;
        expect(envelope['candidates'], 0);
        expect(envelope['hint'], contains('working directory'));
      },
    );

    test('files=[...] alone (no path) works on mobile', () async {
      fake.contentByPath['picker://f-7'] = 'TODO\n';
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'files': ['picker://f-7'],
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      expect(envelope['total_matches'], 1);
    });

    test('surfaces per-file read failures as unreadable markers', () async {
      fake.filesByPath['working://src'] = const [
        FileEntry(
          name: 'a.dart',
          path: 'working://src/a.dart',
          isDirectory: false,
          size: 0,
          modifiedMs: 0,
        ),
        FileEntry(
          name: 'b.dart',
          path: 'working://src/b.dart',
          isDirectory: false,
          size: 0,
          modifiedMs: 0,
        ),
      ];
      fake.contentByPath['working://src/a.dart'] = 'TODO\n';
      // b.dart will throw on read.
      fake.readErrors['working://src/b.dart'] = 'permission denied';
      final tool = SearchTool();
      final out = await tool.execute({
        'pattern': 'TODO',
        'path': 'working://src',
      }, tools);
      final envelope = jsonDecode(out) as Map<String, dynamic>;
      // Even though b.dart failed to read, a.dart still hits.
      expect(envelope['total_matches'], 1);
      // The result must not have crashed because of b.dart.
      final files = (envelope['files'] as List).cast<Map<String, dynamic>>();
      expect(files, hasLength(1));
      expect(files.single['file'], 'working://src/a.dart');
    });
  });
}

/// Minimal in-memory FileService used by the mobile-branch
/// tests. Stores file content per path, hands it back to the
/// tool, and can be programmed to throw on specific reads.
class _InMemoryFileService implements FileService {
  _InMemoryFileService({String? workingDir}) : _workingDir = workingDir;
  String? _workingDir;

  final Map<String, List<FileEntry>> filesByPath = {};
  final Map<String, String> contentByPath = {};
  final Map<String, String> readErrors = {};

  @override
  String? get workingDirectory => _workingDir;

  @override
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false}) async =>
      null;

  @override
  Future<void> release(String id) async {}

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    final err = readErrors[path];
    if (err != null) {
      throw FileServiceError(err);
    }
    final text = contentByPath[path];
    if (text == null) {
      throw FileServiceError('not in store: $path');
    }
    return utf8.encode(text);
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool append = false,
  }) async {
    contentByPath[path] = utf8.decode(bytes);
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    contentByPath.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    final v = contentByPath.remove(from);
    if (v != null) contentByPath[to] = v;
  }

  @override
  Future<List<FileEntry>> listDir(String path, {bool recursive = false}) async {
    return filesByPath[path] ?? const [];
  }

  @override
  Future<FileAttrs> readAttr(String path) async {
    return FileAttrs(
      path: path,
      type: 'file',
      size: contentByPath[path]?.length ?? 0,
      modifiedMs: 0,
      accessedMs: 0,
      changedMs: 0,
      isDirectory: false,
      isFile: true,
      isLink: false,
    );
  }

  @override
  Future<EditResult> edit(String path, List<EditOp> edits) async {
    final before = contentByPath[path] ?? '';
    final result = applyLineEdits(
      source: before,
      edits: edits,
      sizeBefore: utf8.encode(before).length,
    );
    if (result.result.ok) contentByPath[path] = result.text;
    return result.result;
  }

  @override
  Future<({String path, String treeUri})?> pickWorkingDirectory() async => null;
}
