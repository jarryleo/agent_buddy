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
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('edit (desktop)', () {
    test(
      'replaces by an inclusive line range without exact text matching',
      () async {
        final file = File(p.join(workingDir.path, 'a.dart'))
          ..writeAsBytesSync(utf8.encode('line 1\r\n  line 2\r\nline 3'));

        final raw = await tool.execute({
          'action': 'edit',
          'path': file.path,
          'edits': [
            {'start_line': 2, 'end_line': 2, 'content': 'LINE TWO'},
          ],
        }, toolService);
        final env = jsonDecode(raw) as Map<String, dynamic>;

        expect(env['ok'], true);
        expect(env['applied'], 1);
        expect(env['refreshed'], true);
        expect((env['diff'] as List).single['start_line'], 2);
        expect((env['diff'] as List).single['end_line'], 2);
        expect(file.readAsStringSync(), 'line 1\r\nLINE TWO\r\nline 3');
      },
    );

    test(
      'end_line is optional and content can contain inserted lines',
      () async {
        final file = File(p.join(workingDir.path, 'insert.txt'))
          ..writeAsStringSync('A\nB\nC\n');

        await tool.execute({
          'action': 'edit',
          'path': file.path,
          'edits': [
            {'start_line': 2, 'content': 'B\nINSERTED'},
          ],
        }, toolService);

        expect(file.readAsStringSync(), 'A\nB\nINSERTED\nC\n');
      },
    );

    test('empty content deletes the inclusive line range', () async {
      final file = File(p.join(workingDir.path, 'delete.txt'))
        ..writeAsStringSync('keep 1\nremove 2\nremove 3\nkeep 4\n');

      await tool.execute({
        'action': 'edit',
        'path': file.path,
        'edits': [
          {'start_line': 2, 'end_line': 3, 'content': ''},
        ],
      }, toolService);

      expect(file.readAsStringSync(), 'keep 1\nkeep 4\n');
    });

    test(
      'batch edits apply from larger line numbers to smaller ones',
      () async {
        final file = File(p.join(workingDir.path, 'batch.txt'))
          ..writeAsStringSync('L1\nL2\nL3\nL4\nL5\nL6\n');

        final raw = await tool.execute({
          'action': 'edit',
          'path': file.path,
          'edits': [
            {'start_line': 2, 'content': 'L2\nLOW INSERT'},
            {'start_line': 5, 'content': 'HIGH REPLACED\nHIGH INSERT'},
          ],
        }, toolService);

        final env = jsonDecode(raw) as Map<String, dynamic>;
        expect(env['ok'], true);
        expect(
          file.readAsStringSync(),
          'L1\nL2\nLOW INSERT\nL3\nL4\nHIGH REPLACED\nHIGH INSERT\nL6\n',
        );
      },
    );

    test('batch edits reject overlapping ranges without writing', () async {
      final file = File(p.join(workingDir.path, 'overlap.txt'))
        ..writeAsStringSync('A\nB\nC\n');

      final error = await _captureToolError(
        tool.execute({
          'action': 'edit',
          'path': file.path,
          'edits': [
            {'start_line': 1, 'end_line': 2, 'content': 'X'},
            {'start_line': 2, 'content': 'Y'},
          ],
        }, toolService),
      );

      expect(error.message, contains('OVERLAPPING_EDITS'));
      expect(file.readAsStringSync(), 'A\nB\nC\n');
    });

    test(
      'invalid line ranges are tool failures, not successful results',
      () async {
        final file = File(p.join(workingDir.path, 'invalid.txt'))
          ..writeAsStringSync('A\nB\n');

        final error = await _captureToolError(
          tool.execute({
            'action': 'edit',
            'path': file.path,
            'edits': [
              {'start_line': 3, 'content': 'C'},
            ],
          }, toolService),
        );

        expect(error.message, contains('LINE_OUT_OF_RANGE'));
        expect(file.readAsStringSync(), 'A\nB\n');
      },
    );

    test(
      'failed edit on a missing file is surfaced as a tool failure',
      () async {
        final error = await _captureToolError(
          tool.execute({
            'action': 'edit',
            'path': p.join(workingDir.path, 'missing.txt'),
            'edits': [
              {'start_line': 1, 'content': 'x'},
            ],
          }, toolService),
        );

        expect(error.message, contains('PATH_NOT_FOUND'));
      },
    );

    test('UTF-8 BOM is preserved while editing by line number', () async {
      final file = File(p.join(workingDir.path, 'bom.txt'))
        ..writeAsBytesSync([0xef, 0xbb, 0xbf, ...utf8.encode('一\n二')]);

      await tool.execute({
        'action': 'edit',
        'path': file.path,
        'edits': [
          {'start_line': 2, 'content': '贰'},
        ],
      }, toolService);

      expect(file.readAsBytesSync(), [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('一\n贰'),
      ]);
    });
  });

  group('read (desktop)', () {
    test('returns clean line-numbered content for CRLF files', () async {
      final file = File(p.join(workingDir.path, 'read.txt'))
        ..writeAsStringSync('a\r\nb\r\nc\r\n');

      final raw = await tool.execute({
        'action': 'read',
        'path': file.path,
      }, toolService);
      final env = jsonDecode(raw) as Map<String, dynamic>;

      expect(env['total_lines'], 3);
      expect(env['content'], '1|a\n2|b\n3|c');
    });

    test('pattern and page modes keep 1-based line numbers', () async {
      final file = File(p.join(workingDir.path, 'large.txt'))
        ..writeAsStringSync(List.generate(20, (i) => 'L$i').join('\n'));

      final page =
          jsonDecode(
                await tool.execute({
                  'action': 'read',
                  'path': file.path,
                  'offset_lines': 10,
                  'max_lines': 3,
                }, toolService),
              )
              as Map<String, dynamic>;
      expect(page['start_line'], 11);
      expect((page['content'] as String).split('\n').first, '11|L10');

      final pattern =
          jsonDecode(
                await tool.execute({
                  'action': 'read',
                  'path': file.path,
                  'pattern': 'L10',
                }, toolService),
              )
              as Map<String, dynamic>;
      expect(pattern['matches'], 1);
      expect(pattern['content'], contains('11|L10'));
    });
  });

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

    test('routes the three line-edit fields through FileService', () async {
      editSvc.editResponse = EditResult.success(
        applied: 1,
        sizeBefore: 10,
        sizeAfter: 12,
        diff: [
          EditDiffEntry(
            editIndex: 0,
            startLine: 5,
            endLine: 5,
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
          {'start_line': 5, 'content': 'foobar'},
        ],
      }, toolService);

      expect(editSvc.lastEditPath, 'working://a.dart');
      expect(editSvc.lastEdits!.single.startLine, 5);
      expect(editSvc.lastEdits!.single.endLine, isNull);
      expect(editSvc.lastEdits!.single.content, 'foobar');
      expect((jsonDecode(raw) as Map)['ok'], true);
    });

    test('a false EditResult becomes a failed tool call', () async {
      editSvc.editResponse = EditResult.error(
        code: 'LINE_OUT_OF_RANGE',
        message: 'bad line',
        failedIndex: 0,
        startLine: 99,
        endLine: 99,
      );

      final error = await _captureToolError(
        tool.execute({
          'action': 'edit',
          'path': 'working://a.dart',
          'edits': [
            {'start_line': 99, 'content': 'x'},
          ],
        }, toolService),
      );

      expect(error.message, contains('LINE_OUT_OF_RANGE'));
    });
  });
}

Future<ToolException> _captureToolError(Future<String> future) async {
  try {
    await future;
    fail('expected ToolException');
  } on ToolException catch (error) {
    return error;
  }
}

class _EditTestService implements FileService {
  List<int> readResult = const [];
  EditResult? editResponse;
  String? lastEditPath;
  List<EditOp>? lastEdits;

  @override
  String? get workingDirectory => null;

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) async =>
      readResult;

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
