import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/models/picked_file.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/platform/file_service.dart';
import 'package:agent_buddy/services/platform/file_service_impl.dart';
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
  late StorageService storage;
  late ToolService toolService;
  late FileTool tool;

  setUpAll(ChatSessionRepository.registerAdapters);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('file_tool_edit_');
    Hive.init(tempDir.path);
    workingDir = await tempDir.createTemp('working_');
    storage = StorageService();
    await storage.init();
    await storage.setModelWorkingDirectory(workingDir.path);
    toolService = ToolService(
      storage: storage,
      fileBuilder: () => FileServiceImpl(
        workingDirectoryLookup: () => storage.modelWorkingDirectory,
      ),
    );
    addTearDown(toolService.dispose);
    tool = FileTool();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  // ----- desktop edit (default platform in test host) -----

  group('edit (desktop)', () {
    test('replaces a unique anchor and reports matched_line', () async {
      final f = File(p.join(workingDir.path, 'a.dart'));
      f.writeAsStringSync('line 1\nline 2\nline 3\n');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'line 2\n', 'new_text': 'LINE TWO\n'},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], true);
      expect(env['applied'], 1);
      expect((env['diff'] as List).length, 1);
      final diff = (env['diff'] as List).first as Map<String, dynamic>;
      expect(diff['matched_line'], 2);
      expect(diff['old_preview'], contains('line 2'));
      expect(f.readAsStringSync(), 'line 1\nLINE TWO\nline 3\n');
    });

    test('batch edit applies every op and reports per-edit diff', () async {
      final f = File(p.join(workingDir.path, 'b.dart'));
      f.writeAsStringSync('''
void foo() {
  return 1;
}

void bar() {
  return 2;
}
''');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'return 1;', 'new_text': 'return 10;'},
          {'old_text': 'return 2;', 'new_text': 'return 20;'},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], true);
      expect(env['applied'], 2);
      final after = f.readAsStringSync();
      expect(after, contains('return 10;'));
      expect(after, contains('return 20;'));
    });

    test('empty new_text deletes the matched block', () async {
      final f = File(p.join(workingDir.path, 'c.dart'));
      f.writeAsStringSync('keep this\nDROP THIS LINE\nkeep this too\n');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'DROP THIS LINE\n', 'new_text': ''},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], true);
      expect(f.readAsStringSync(), 'keep this\nkeep this too\n');
    });

    test('global_replace replaces every match', () async {
      final f = File(p.join(workingDir.path, 'd.dart'));
      f.writeAsStringSync('foo foo foo\n');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'foo', 'new_text': 'bar', 'global_replace': true},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], true);
      expect(f.readAsStringSync(), 'bar bar bar\n');
      final diff = (env['diff'] as List).first as Map<String, dynamic>;
      expect(diff['replacements'], 3);
    });

    test('old_text not found returns near_matches + soft failure', () async {
      final f = File(p.join(workingDir.path, 'e.dart'));
      f.writeAsStringSync('line alpha\nline beta\nline gamma\n');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'line omega\n', 'new_text': 'replaced\n'},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], false);
      expect(env['error_code'], 'OLD_TEXT_NOT_FOUND');
      expect(env['failed_index'], 0);
      final nearMatches = (env['near_matches'] as List?) ?? const [];
      expect(nearMatches.length, greaterThan(0));
      // File is untouched on failure.
      expect(f.readAsStringSync(), 'line alpha\nline beta\nline gamma\n');
    });

    test('non-unique old_text returns candidates with line numbers', () async {
      final f = File(p.join(workingDir.path, 'f.dart'));
      f.writeAsStringSync('return 1;\nreturn 2;\nreturn 3;\n');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'return ', 'new_text': 'yield '},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], false);
      expect(env['error_code'], 'OLD_TEXT_NOT_UNIQUE');
      final candidates = env['candidates'] as List;
      expect(candidates.length, 3);
      expect((candidates.first as Map)['line'], 1);
    });

    test('first failing edit rolls back the whole batch', () async {
      final f = File(p.join(workingDir.path, 'g.dart'));
      f.writeAsStringSync('A\nB\nC\n');

      final raw = await tool.execute({
        'action': 'edit',
        'path': f.path,
        'edits': [
          {'old_text': 'A\n', 'new_text': 'AAA\n'},
          {'old_text': 'B\n', 'new_text': 'BBB\n'},
          {'old_text': 'Z\n', 'new_text': 'ZZZ\n'},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], false);
      expect(env['failed_index'], 2);
      // File is untouched - atomic rollback.
      expect(f.readAsStringSync(), 'A\nB\nC\n');
    });

    test('edit on a missing file returns a soft PATH_NOT_FOUND', () async {
      final missing = p.join(workingDir.path, 'does_not_exist.dart');
      final raw = await tool.execute({
        'action': 'edit',
        'path': missing,
        'edits': [
          {'old_text': 'x', 'new_text': 'y'},
        ],
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['ok'], false);
      expect(env['error_code'], 'PATH_NOT_FOUND');
    });

    test('missing edits array raises ToolException', () async {
      final f = File(p.join(workingDir.path, 'h.dart'));
      f.writeAsStringSync('x');
      Object? caught;
      try {
        await tool.execute({'action': 'edit', 'path': f.path}, toolService);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), contains('edits'));
    });

    test('empty old_text raises ToolException via EditOp.fromJson', () async {
      final f = File(p.join(workingDir.path, 'i.dart'));
      f.writeAsStringSync('x');
      Object? caught;
      try {
        await tool.execute({
          'action': 'edit',
          'path': f.path,
          'edits': [
            {'old_text': '', 'new_text': 'x'},
          ],
        }, toolService);
      } catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught.toString(), contains('old_text'));
    });
  });

  // ----- read (desktop) -----

  group('read (desktop, enhanced)', () {
    test('returns line-numbered content by default', () async {
      final f = File(p.join(workingDir.path, 'r.dart'));
      f.writeAsStringSync('a\nb\nc\n');

      final raw = await tool.execute({
        'action': 'read',
        'path': f.path,
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['mode'], 'full');
      expect(env['total_lines'], 3);
      expect(env['returned_lines'], 3);
      expect(env['content'], '1|a\n2|b\n3|c');
    });

    test('offset_lines + max_lines return a page with a hint', () async {
      final f = File(p.join(workingDir.path, 'big.dart'));
      f.writeAsStringSync(List.generate(1000, (i) => 'L$i').join('\n'));

      final raw = await tool.execute({
        'action': 'read',
        'path': f.path,
        'offset_lines': 100,
        'max_lines': 50,
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['mode'], 'page');
      expect(env['start_line'], 101);
      expect(env['end_line'], 150);
      expect(env['total_lines'], 1000);
      expect(env['returned_lines'], 50);
      expect(env['truncated'], true);
      expect(env['truncation_hint'], contains('offset_lines=150'));
      expect((env['content'] as String).split('\n').first, '101|L100');
    });

    test('pattern returns only matching lines plus 2-line context', () async {
      final f = File(p.join(workingDir.path, 'g.dart'));
      f.writeAsStringSync('''
void foo() {
  print("hello");
}

void bar() {
  print("world");
}
''');

      final raw = await tool.execute({
        'action': 'read',
        'path': f.path,
        'pattern': 'print',
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['mode'], 'pattern');
      expect(env['matches'], 2);
      expect(env['returned_lines'], greaterThanOrEqualTo(2));
      final content = env['content'] as String;
      expect(content, contains('print'));
      final firstLine = content.split('\n').first;
      expect(firstLine, matches(RegExp(r'^\d+\|')));
    });

    test('a binary file still returns the legacy binary envelope', () async {
      final f = File(p.join(workingDir.path, 'b.bin'));
      f.writeAsBytesSync([0xff, 0x00, 0xfe]);

      final raw = await tool.execute({
        'action': 'read',
        'path': f.path,
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['encoding'], 'binary');
      expect(env['content'], contains('binary file'));
    });
  });

  // ----- mobile branch -----

  group('edit (mobile branch via injected FileService)', () {
    late _EditTestService editSvc;

    setUp(() {
      editSvc = _EditTestService();
      toolService.dispose();
      toolService = ToolService(fileBuilder: () => editSvc);
      addTearDown(toolService.dispose);
      overridePlatform(isMobileValue: true, isDesktopValue: false);
    });

    tearDown(resetPlatformOverrides);

    test(
      'routes edit through the FileService and returns its envelope',
      () async {
        editSvc.editResponse = EditResult.success(
          applied: 1,
          sizeBefore: 10,
          sizeAfter: 12,
          diff: [
            EditDiffEntry(
              editIndex: 0,
              matchedLine: 5,
              oldPreview: 'foo',
              newPreview: 'foobar',
              replacements: 1,
            ),
          ],
        );
        final raw = await tool.execute({
          'action': 'edit',
          'path': 'working://a.dart',
          'edits': [
            {'old_text': 'foo', 'new_text': 'foobar'},
          ],
        }, toolService);
        expect(editSvc.lastEditPath, 'working://a.dart');
        expect(editSvc.lastEdits, hasLength(1));
        expect(editSvc.lastEdits!.first.oldText, 'foo');
        final env = jsonDecode(raw) as Map<String, dynamic>;
        expect(env['ok'], true);
        expect(env['applied'], 1);
        expect((env['diff'] as List).first['matched_line'], 5);
      },
    );

    test(
      'soft-error envelopes from the service are surfaced as JSON',
      () async {
        editSvc.editResponse = EditResult.notUnique(
          failedIndex: 0,
          sizeBefore: 100,
          foundCount: 3,
          candidates: const [
            EditCandidate(line: 1, preview: 'return 1;'),
            EditCandidate(line: 2, preview: 'return 2;'),
            EditCandidate(line: 3, preview: 'return 3;'),
          ],
        );
        final raw = await tool.execute({
          'action': 'edit',
          'path': 'working://a.dart',
          'edits': [
            {'old_text': 'return ', 'new_text': 'yield '},
          ],
        }, toolService);
        final env = jsonDecode(raw) as Map<String, dynamic>;
        expect(env['ok'], false);
        expect(env['error_code'], 'OLD_TEXT_NOT_UNIQUE');
        expect((env['candidates'] as List).length, 3);
      },
    );

    test('read on mobile uses the enhanced line-numbered envelope', () async {
      editSvc.readResponse = 'alpha\nbeta\ngamma\n';
      final raw = await tool.execute({
        'action': 'read',
        'path': 'working://a.dart',
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;
      expect(env['mode'], 'full');
      expect(env['total_lines'], 3);
      expect(env['content'], '1|alpha\n2|beta\n3|gamma');
    });
  });
}

/// In-memory FileService that records edit calls for the
/// mobile-branch tests above. Reads are served from a fixed
/// string so the enhanced read envelope has something to chew
/// on.
class _EditTestService implements FileService {
  List<int> readResult = const [];
  String? readResultText;
  EditResult? editResponse;
  String? lastEditPath;
  List<EditOp>? lastEdits;

  String? get readResponse => readResultText;

  set readResponse(String value) {
    readResultText = value;
    readResult = value.codeUnits;
  }

  @override
  String? get workingDirectory => null;

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    return readResult;
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool append = false,
  }) async {}

  @override
  Future<EditResult> edit(String path, List<EditOp> edits) async {
    lastEditPath = path;
    lastEdits = edits;
    return editResponse ??
        EditResult.success(
          applied: edits.length,
          sizeBefore: 0,
          sizeAfter: 0,
          diff: const [],
        );
  }

  @override
  Future<({String path, String treeUri})?> pickWorkingDirectory() async => null;

  @override
  Future<void> rename(String from, String to) async {}

  @override
  Future<void> delete(String path, {bool recursive = false}) async {}

  @override
  Future<FileAttrs> readAttr(String path) async => FileAttrs(
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

  @override
  Future<List<FileEntry>> listDir(
    String path, {
    bool recursive = false,
  }) async => const [];

  @override
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false}) async =>
      null;

  @override
  Future<void> release(String id) async {}
}
