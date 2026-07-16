import 'dart:io';
import 'dart:convert';

import 'package:agent_buddy/models/picked_file.dart';
import 'package:agent_buddy/services/platform/file_service.dart';
import 'package:agent_buddy/services/platform/file_service_impl.dart';
import 'package:agent_buddy/services/platform/file_service_stub.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileServiceStub', () {
    test('every op throws FileServiceNotSupportedError', () async {
      const svc = FileServiceStub();
      Future<void> expectNotSupported(Future<Object?> Function() op) async {
        try {
          await op();
          fail('expected FileServiceNotSupportedError');
        } on FileServiceNotSupportedError {
          // ok
        }
      }

      await expectNotSupported(() => svc.pick());
      await expectNotSupported(() => svc.release('x'));
      await expectNotSupported(() => svc.read('app://documents/x'));
      await expectNotSupported(() => svc.write('app://documents/x', [1, 2, 3]));
      await expectNotSupported(() => svc.delete('app://documents/x'));
      await expectNotSupported(() => svc.rename('a', 'b'));
      await expectNotSupported(() => svc.listDir('app://documents'));
      await expectNotSupported(() => svc.readAttr('app://documents/x'));
    });
  });

  group('Path helpers', () {
    test('isPickerPath recognises only the picker:// scheme', () {
      expect(isPickerPath('picker://abc'), isTrue);
      expect(isPickerPath('picker://abc/'), isFalse);
      expect(isPickerPath('app://documents/x'), isFalse);
      expect(isPickerPath('http://x'), isFalse);
      expect(isPickerPath(''), isFalse);
      expect(isPickerPath('picker://'), isFalse);
    });

    test('pickerIdOf extracts the id', () {
      expect(pickerIdOf('picker://f-1'), 'f-1');
      expect(pickerIdOf('app://x'), isNull);
      expect(pickerIdOf('picker://'), isNull);
    });

    test('parseAppPath splits root and segments', () {
      final a = parseAppPath('app://documents/foo/bar.txt');
      expect(a, isNotNull);
      expect(a!.root, AppSandbox.documents);
      expect(a.segments, ['foo', 'bar.txt']);

      final b = parseAppPath('app://temp/');
      expect(b, isNotNull);
      expect(b!.root, AppSandbox.temp);
      expect(b.segments, isEmpty);

      expect(parseAppPath('picker://x'), isNull);
      expect(parseAppPath('app://unknown/x'), isNull);
      expect(parseAppPath('http://x'), isNull);
    });
  });

  group('FileServiceImpl (sandbox + MethodChannel mocking)', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    late Directory sandboxRoot;
    late FileServiceImpl svc;

    setUp(() async {
      sandboxRoot = await Directory.systemTemp.createTemp('file_service_');
      final docs = Directory('${sandboxRoot.path}/docs');
      final temp = Directory('${sandboxRoot.path}/temp');
      final support = Directory('${sandboxRoot.path}/support');
      await docs.create(recursive: true);
      await temp.create(recursive: true);
      await support.create(recursive: true);

      // Mock the picker channel. Tests that touch picker
      // paths can override the handler to return a fake
      // PickedFile payload or simulate cancellation.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('agent_buddy/file'), (
            call,
          ) async {
            if (call.method == 'pick') {
              return {'cancelled': true};
            }
            return null;
          });

      svc = FileServiceImpl(
        overrideDocs: Future.value(docs),
        overrideTemp: Future.value(temp),
        overrideSupport: Future.value(support),
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('agent_buddy/file'),
            null,
          );
      if (await sandboxRoot.exists()) {
        await sandboxRoot.delete(recursive: true);
      }
    });

    test('pick returns null when the bridge says cancelled', () async {
      final result = await svc.pick();
      expect(result, isNull);
    });

    test('pick with readOnly forwards the flag to the bridge', () async {
      Map<String, dynamic>? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('agent_buddy/file'), (
            call,
          ) async {
            if (call.method == 'pick') {
              captured = (call.arguments as Map).cast<String, dynamic>();
              return {'cancelled': true};
            }
            return null;
          });
      await svc.pick(mimeType: 'text/plain', readOnly: true);
      expect(captured, isNotNull);
      expect(captured!['mime_type'], 'text/plain');
      expect(captured!['read_only'], true);
    });

    test('read / write / delete round-trip on app://documents/', () async {
      await svc.write('app://documents/hello.txt', utf8.encode('hi'));
      final bytes = await svc.read('app://documents/hello.txt');
      expect(String.fromCharCodes(bytes), 'hi');
      await svc.delete('app://documents/hello.txt');
      expect(
        () => svc.read('app://documents/hello.txt'),
        throwsA(isA<FileServiceError>()),
      );
    });

    test('write creates missing parent directories', () async {
      await svc.write('app://documents/sub/dir/file.txt', utf8.encode('deep'));
      final got = await svc.read('app://documents/sub/dir/file.txt');
      expect(String.fromCharCodes(got), 'deep');
    });

    test('append concatenates and rejects missing file', () async {
      await svc.write('app://temp/log.txt', utf8.encode('a'));
      await svc.write('app://temp/log.txt', utf8.encode('b'), append: true);
      final got = await svc.read('app://temp/log.txt');
      expect(String.fromCharCodes(got), 'ab');
      expect(
        () =>
            svc.write('app://temp/missing.txt', utf8.encode('x'), append: true),
        throwsA(isA<FileServiceError>()),
      );
    });

    test('read rejects files above maxBytes', () async {
      final big = Uint8List(64 * 1024);
      await svc.write('app://documents/big.bin', big);
      expect(
        () => svc.read('app://documents/big.bin', maxBytes: 1024),
        throwsA(isA<FileServiceError>()),
      );
    });

    test('listDir returns entries under the right root', () async {
      await svc.write('app://documents/a.txt', utf8.encode('a'));
      await svc.write('app://documents/sub/b.txt', utf8.encode('b'));
      final entries = await svc.listDir('app://documents/');
      final names = entries.map((e) => e.name).toList()..sort();
      expect(names, ['a.txt', 'sub']);
      final a = entries.firstWhere((e) => e.name == 'a.txt');
      expect(a.isDirectory, isFalse);
      expect(a.path, 'app://documents/a.txt');
      final sub = entries.firstWhere((e) => e.name == 'sub');
      expect(sub.isDirectory, isTrue);
    });

    test('listDir rejects picker://<id> paths', () async {
      expect(
        () => svc.listDir('picker://f-1'),
        throwsA(isA<FileServiceError>()),
      );
    });

    test(
      'delete refuses to recurse into a non-empty dir without recursive=true',
      () async {
        await svc.write('app://documents/x/y.txt', utf8.encode('y'));
        final xDir = Directory(
          '${sandboxRoot.path}/docs${Platform.pathSeparator}x',
        );
        // Sanity check that the dir actually exists on disk at this point.
        expect(
          xDir.existsSync(),
          isTrue,
          reason:
              'x dir should exist after write; otherwise FileServiceImpl.write did not create it',
        );
        expect(
          xDir.listSync(),
          isNotEmpty,
          reason: 'x dir should have at least y.txt',
        );
        expect(
          () => svc.delete('app://documents/x'),
          throwsA(isA<FileServiceError>()),
        );
        await svc.delete('app://documents/x', recursive: true);
      },
    );

    test('rename refuses to clobber and refuses picker paths', () async {
      await svc.write('app://documents/a.txt', utf8.encode('a'));
      await svc.write('app://documents/b.txt', utf8.encode('b'));
      expect(
        () => svc.rename('app://documents/a.txt', 'app://documents/b.txt'),
        throwsA(isA<FileServiceError>()),
      );
      expect(
        () => svc.rename('picker://x', 'app://documents/y'),
        throwsA(isA<FileServiceError>()),
      );
      await svc.rename('app://documents/a.txt', 'app://documents/c.txt');
      final got = await svc.read('app://documents/c.txt');
      expect(String.fromCharCodes(got), 'a');
    });

    test('readAttr returns a structured envelope', () async {
      await svc.write('app://support/d.txt', utf8.encode('data'));
      final attrs = await svc.readAttr('app://support/d.txt');
      expect(attrs.isFile, isTrue);
      expect(attrs.isDirectory, isFalse);
      expect(attrs.size, 4);
      expect(attrs.path, 'app://support/d.txt');
    });

    test('sandbox-escape via .. is rejected', () async {
      expect(
        () => svc.read('app://documents/../../etc/passwd'),
        throwsA(isA<FileServiceError>()),
      );
    });

    test('read on a picker://<id> delegates to the bridge', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('agent_buddy/file'), (
            call,
          ) async {
            if (call.method == 'readPicker') {
              final args = (call.arguments as Map).cast<String, dynamic>();
              expect(args['id'], 'f-1');
              expect(args['max_bytes'], 4096);
              return Uint8List.fromList([104, 105]); // "hi"
            }
            return null;
          });
      final got = await svc.read('picker://f-1', maxBytes: 4096);
      expect(String.fromCharCodes(got), 'hi');
    });

    test(
      'readPicker surfaces PICKER_DENIED as a friendly FileServiceError',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('agent_buddy/file'), (
              call,
            ) async {
              throw PlatformException(
                code: 'PICKER_DENIED',
                message: 'access revoked',
              );
            });
        try {
          await svc.read('picker://f-1');
          fail('expected FileServiceError');
        } on FileServiceError catch (e) {
          expect(e.message, contains('access revoked'));
        }
      },
    );
  });

  group('Working directory resolution (mobile)', () {
    late Directory workingRoot;
    late FileServiceImpl workingSvc;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      workingRoot = await Directory.systemTemp.createTemp('file_service_wd_');
      // Seed with a file + subdir to exercise listDir / read.
      File('${workingRoot.path}/hello.txt').writeAsStringSync('hi');
      Directory('${workingRoot.path}/sub').createSync();
      File('${workingRoot.path}/sub/inner.txt').writeAsStringSync('inner');

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('agent_buddy/file'),
            (call) async => null,
          );

      final sandbox = await Directory.systemTemp.createTemp(
        'file_service_wd_sb_',
      );
      workingSvc = FileServiceImpl(
        overrideDocs: Future.value(Directory('${sandbox.path}/docs')),
        overrideTemp: Future.value(Directory('${sandbox.path}/temp')),
        overrideSupport: Future.value(Directory('${sandbox.path}/support')),
        workingDirectoryLookup: () => workingRoot.path,
      );
      addTearDown(() async {
        if (await workingRoot.exists()) {
          await workingRoot.delete(recursive: true);
        }
        if (await sandbox.exists()) {
          await sandbox.delete(recursive: true);
        }
      });
    });

    test('workingDirectory returns the configured value', () {
      expect(workingSvc.workingDirectory, workingRoot.path);
    });

    test(
      'read on a bare relative path resolves into the working dir',
      () async {
        final got = await workingSvc.read('hello.txt');
        expect(String.fromCharCodes(got), 'hi');
      },
    );

    test(
      'read on a working://<rel> path resolves into the working dir',
      () async {
        final got = await workingSvc.read('working://sub/inner.txt');
        expect(String.fromCharCodes(got), 'inner');
      },
    );

    test('write + read round-trip a bare relative path', () async {
      await workingSvc.write('note.txt', utf8.encode('written'));
      final got = await workingSvc.read('note.txt');
      expect(String.fromCharCodes(got), 'written');
    });

    test('listDir on bare empty path lists the working dir', () async {
      final entries = await workingSvc.listDir('');
      final names = entries.map((e) => e.name).toSet();
      expect(names, containsAll(['hello.txt', 'sub']));
    });

    test(
      'listDir on working:// returns working:// paths for children',
      () async {
        final entries = await workingSvc.listDir('working://');
        final hello = entries.firstWhere((e) => e.name == 'hello.txt');
        expect(hello.path, 'working://hello.txt');
        expect(hello.isDirectory, isFalse);
      },
    );

    test(
      'listDir on working://sub/ returns working://sub/<name> children',
      () async {
        final entries = await workingSvc.listDir('working://sub');
        expect(entries, hasLength(1));
        expect(entries.first.path, 'working://sub/inner.txt');
      },
    );

    test(
      'delete refuses to clobber and respects the working dir boundary',
      () async {
        await workingSvc.write('a.txt', utf8.encode('a'));
        await workingSvc.write('b.txt', utf8.encode('b'));
        expect(
          () => workingSvc.rename('a.txt', 'b.txt'),
          throwsA(isA<FileServiceError>()),
        );
        await workingSvc.rename('a.txt', 'c.txt');
        final got = await workingSvc.read('c.txt');
        expect(String.fromCharCodes(got), 'a');
      },
    );

    test('sandbox-escape via .. is rejected on the working dir', () async {
      expect(
        () => workingSvc.read('../etc/passwd'),
        throwsA(isA<FileServiceError>()),
      );
      expect(
        () => workingSvc.read('working://../etc/passwd'),
        throwsA(isA<FileServiceError>()),
      );
    });

    test('absolute paths are rejected on mobile (no raw OS paths)', () async {
      expect(
        () => workingSvc.read('/etc/passwd'),
        throwsA(isA<FileServiceError>()),
      );
      expect(
        () => workingSvc.read('working:///etc/passwd'),
        throwsA(isA<FileServiceError>()),
      );
    });

    test('invalid scheme surfaces a clear FileServiceError', () async {
      expect(
        () => workingSvc.read('http://example.com/foo'),
        throwsA(isA<FileServiceError>()),
      );
      expect(
        () => workingSvc.read('content://com.example/123'),
        throwsA(isA<FileServiceError>()),
      );
    });
  });

  group('Working directory error paths (mobile)', () {
    test(
      'relative path without a working directory throws a clear error',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final sandbox = await Directory.systemTemp.createTemp(
          'file_service_nowd_',
        );
        addTearDown(() async {
          if (await sandbox.exists()) await sandbox.delete(recursive: true);
        });
        final svc = FileServiceImpl(
          overrideDocs: Future.value(Directory('${sandbox.path}/docs')),
          overrideTemp: Future.value(Directory('${sandbox.path}/temp')),
          overrideSupport: Future.value(Directory('${sandbox.path}/support')),
          // No workingDirectoryLookup → no working dir.
        );
        expect(
          () => svc.read('hello.txt'),
          throwsA(
            isA<FileServiceError>().having(
              (e) => e.message,
              'message',
              contains('no working directory'),
            ),
          ),
        );
      },
    );

    test(
      'working://<rel> without a working directory throws a clear error',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final sandbox = await Directory.systemTemp.createTemp(
          'file_service_nowd2_',
        );
        addTearDown(() async {
          if (await sandbox.exists()) await sandbox.delete(recursive: true);
        });
        final svc = FileServiceImpl(
          overrideDocs: Future.value(Directory('${sandbox.path}/docs')),
          overrideTemp: Future.value(Directory('${sandbox.path}/temp')),
          overrideSupport: Future.value(Directory('${sandbox.path}/support')),
        );
        expect(
          () => svc.read('working://foo/bar.txt'),
          throwsA(isA<FileServiceError>()),
        );
      },
    );
  });

  group('Path helpers — working scheme', () {
    test('isWorkingPath recognises only the working:// scheme', () {
      expect(isWorkingPath('working://foo'), isTrue);
      expect(isWorkingPath('working://'), isTrue);
      expect(isWorkingPath('app://documents/x'), isFalse);
      expect(isWorkingPath('picker://x'), isFalse);
      expect(isWorkingPath('foo/bar.txt'), isFalse);
      expect(isWorkingPath(''), isFalse);
    });

    test('parseWorkingPath splits a relative working path', () {
      final r = parseWorkingPath('working://foo/bar.txt');
      expect(r, isNotNull);
      expect(r!.segments, ['foo', 'bar.txt']);
      expect(r.absoluteOverride, isNull);
    });

    test('parseWorkingPath captures an absolute override (working:///)', () {
      final r = parseWorkingPath('working:///sdcard/Download/foo');
      expect(r, isNotNull);
      expect(r!.absoluteOverride, '/sdcard/Download/foo');
      expect(r.segments, isEmpty);
    });

    test('parseWorkingPath returns null for non-working inputs', () {
      expect(parseWorkingPath('app://documents/x'), isNull);
      expect(parseWorkingPath('picker://x'), isNull);
      expect(parseWorkingPath('foo/bar.txt'), isNull);
    });
  });

  group('ToolService.file wiring', () {
    test('injects a custom FileService via the builder', () {
      final custom = _InMemoryFileService();
      final tools = ToolService(fileBuilder: () => custom);
      expect(tools.file, same(custom));
    });

    test('runFile delegates to the file tool', () {
      // Just assert the tool is registered. The desktop /
      // mobile branch is selected by the platform helper at
      // execute time, not by ToolService.
      final tool = ToolRegistry.byId('file');
      expect(tool, isNotNull);
      expect(tool!.id, 'file');
    });
  });
}

class _InMemoryFileService implements FileService {
  final Map<String, List<int>> docs = {};

  @override
  String? get workingDirectory => null;

  @override
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false}) async {
    return PickedFile(
      id: 'fake',
      name: 'fake.txt',
      size: 4,
      mimeType: mimeType,
      path: 'picker://fake',
    );
  }

  @override
  Future<void> release(String id) async {}

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    return docs[path] ?? [];
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool append = false,
  }) async {
    docs[path] = append ? [...?docs[path], ...bytes] : bytes;
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    docs.remove(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    final v = docs.remove(from);
    if (v != null) docs[to] = v;
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
      size: docs[path]?.length ?? 0,
      modifiedMs: 0,
      accessedMs: 0,
      changedMs: 0,
      isDirectory: false,
      isFile: true,
      isLink: false,
    );
  }
}
