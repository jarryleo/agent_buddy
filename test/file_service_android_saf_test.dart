import 'dart:io';

import 'package:agent_buddy/models/picked_file.dart';
import 'package:agent_buddy/services/platform/file_service_impl.dart';
import 'package:agent_buddy/services/platform/working_dir_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake `WorkingDirBackend` that records every call. Useful
/// for asserting that the `FileService` correctly translates
/// its public API (e.g. `write('working://foo.txt', bytes)`)
/// into the SAF backend's vocabulary (`writeRel('foo.txt', ...)`)
/// without going through the platform channel.
class _FakeWorkingDirBackend implements WorkingDirBackend {
  final List<({String relPath, Uint8List bytes, bool append})> writes = [];
  final List<({String relPath, int maxBytes})> reads = [];
  final List<String> mkdirs = [];
  final List<({String relPath, bool recursive})> deletes = [];
  final List<({String from, String to})> renames = [];
  final List<({String relPath, bool recursive})> lists = [];
  final List<String> readAttrs = [];

  /// Optional pre-canned responses for the next op.
  Object? nextWriteResult;
  Uint8List? nextReadResult;
  void Function(String relPath)? onMkdirs;
  void Function(String relPath)? onDelete;
  void Function(String from, String to)? onRename;
  List<FileEntry>? nextListResult;
  FileAttrs? nextReadAttrResult;
  ({String path, String treeUri})? nextPickResult;

  /// Counters for the auth-cancellation test. When set, the
  /// next [writeRel] / [readRel] / etc. throws
  /// [WorkingDirCancelledException].
  int cancelledOnceCount = 0;
  bool cancelledOnce = false;

  @override
  Future<({String path, String treeUri})?> pickWorkingDirectory() async {
    return nextPickResult;
  }

  @override
  Future<void> writeRel(
    String relPath,
    Uint8List bytes, {
    bool append = false,
  }) async {
    writes.add((relPath: relPath, bytes: bytes, append: append));
    if (cancelledOnce) {
      cancelledOnce = false;
      cancelledOnceCount++;
      throw const WorkingDirCancelledException();
    }
    final r = nextWriteResult;
    if (r is Exception) throw r;
    if (r != null) throw r;
  }

  @override
  Future<Uint8List> readRel(String relPath, {required int maxBytes}) async {
    reads.add((relPath: relPath, maxBytes: maxBytes));
    if (cancelledOnce) {
      cancelledOnce = false;
      cancelledOnceCount++;
      throw const WorkingDirCancelledException();
    }
    return nextReadResult ?? Uint8List(0);
  }

  @override
  Future<void> mkdirsRel(String relPath) async {
    mkdirs.add(relPath);
    onMkdirs?.call(relPath);
  }

  @override
  Future<List<FileEntry>> listRel(
    String relPath, {
    bool recursive = false,
  }) async {
    lists.add((relPath: relPath, recursive: recursive));
    return nextListResult ?? const [];
  }

  @override
  Future<void> deleteRel(String relPath, {bool recursive = false}) async {
    deletes.add((relPath: relPath, recursive: recursive));
    onDelete?.call(relPath);
  }

  @override
  Future<void> renameRel(String from, String to) async {
    renames.add((from: from, to: to));
    onRename?.call(from, to);
  }

  @override
  Future<FileAttrs> readAttrRel(String relPath) async {
    readAttrs.add(relPath);
    return nextReadAttrResult ??
        FileAttrs(
          path: 'working://$relPath',
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileServiceImpl (Android SAF routing)', () {
    late _FakeWorkingDirBackend backend;
    late FileServiceImpl svc;

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('agent_buddy/file'), (
            call,
          ) async {
            // All picker paths (picker://<id>) still route through
            // the existing channel; tests below don't exercise
            // them, so a default null response is fine.
            if (call.method == 'pick') {
              return {'cancelled': true};
            }
            return null;
          });
      backend = _FakeWorkingDirBackend();
      svc = FileServiceImpl(
        workingDirectoryLookup: () => '/storage/emulated/0/Download/test',
        workingDirBackend: backend,
        isAndroid: true,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('agent_buddy/file'),
            null,
          );
    });

    test('write on a working://<rel> path routes to writeRel', () async {
      await svc.write('working://foo/bar.txt', 'hello'.codeUnits);
      expect(backend.writes, hasLength(1));
      expect(backend.writes.single.relPath, 'foo/bar.txt');
      expect(backend.writes.single.append, isFalse);
      expect(String.fromCharCodes(backend.writes.single.bytes), 'hello');
    });

    test('write on a bare relative path also routes to writeRel', () async {
      await svc.write('baz.txt', 'data'.codeUnits);
      expect(backend.writes.single.relPath, 'baz.txt');
    });

    test('append routes to writeRel with append=true', () async {
      await svc.write('log.txt', 'line'.codeUnits, append: true);
      expect(backend.writes.single.append, isTrue);
    });

    test('read on a working://<rel> path routes to readRel', () async {
      backend.nextReadResult = Uint8List.fromList('payload'.codeUnits);
      final got = await svc.read('working://a/b.bin', maxBytes: 4096);
      expect(String.fromCharCodes(got), 'payload');
      expect(backend.reads.single.relPath, 'a/b.bin');
      expect(backend.reads.single.maxBytes, 4096);
    });

    test(
      'read surfaces FileTooLarge from the backend as a friendly error',
      () async {
        backend.nextReadResult = Uint8List(64 * 1024);
        await expectLater(
          svc.read('foo.bin', maxBytes: 1024),
          throwsA(
            isA<FileServiceError>().having(
              (e) => e.message,
              'message',
              contains('file too large'),
            ),
          ),
        );
      },
    );

    test('listDir routes to listRel and returns working:// entries', () async {
      backend.nextListResult = const [
        FileEntry(
          name: 'a.txt',
          path: 'working://a.txt',
          isDirectory: false,
          size: 5,
          modifiedMs: 0,
        ),
        FileEntry(
          name: 'sub',
          path: 'working://sub',
          isDirectory: true,
          size: 0,
          modifiedMs: 0,
        ),
      ];
      final out = await svc.listDir('working://');
      expect(out, hasLength(2));
      // listDir sorts directories first, then files
      // alphabetically — `sub` (dir) precedes `a.txt` (file).
      expect(out.first.name, 'sub');
      expect(out.first.path, 'working://sub');
      expect(out.last.name, 'a.txt');
      expect(out.last.path, 'working://a.txt');
      expect(backend.lists.single.relPath, '');
    });

    test('listDir on a working://sub/ forwards the rel path', () async {
      await svc.listDir('working://sub', recursive: true);
      expect(backend.lists.single.relPath, 'sub');
      expect(backend.lists.single.recursive, isTrue);
    });

    test('delete routes to deleteRel', () async {
      await svc.delete('working://foo.txt', recursive: true);
      expect(backend.deletes.single.relPath, 'foo.txt');
      expect(backend.deletes.single.recursive, isTrue);
    });

    test('rename routes to renameRel with the relPath form', () async {
      await svc.rename('working://old.txt', 'working://new.txt');
      expect(backend.renames.single, (from: 'old.txt', to: 'new.txt'));
    });

    test('readAttr routes to readAttrRel and returns the envelope', () async {
      backend.nextReadAttrResult = FileAttrs(
        path: 'working://foo.txt',
        type: 'file',
        size: 42,
        modifiedMs: 100,
        accessedMs: 100,
        changedMs: 100,
        isDirectory: false,
        isFile: true,
        isLink: false,
      );
      final attrs = await svc.readAttr('working://foo.txt');
      expect(attrs.size, 42);
      expect(backend.readAttrs.single, 'foo.txt');
    });

    test(
      'user cancelling re-auth throws a friendly FileServiceError',
      () async {
        backend.cancelledOnce = true;
        try {
          await svc.write('working://foo.txt', 'x'.codeUnits);
          fail('expected FileServiceError');
        } on FileServiceError catch (e) {
          expect(e.message, contains('working directory access was denied'));
          expect(e.message, contains('chat toolbar'));
        }
        // And the backend only saw the cancelled throw, not
        // any retry — Dart side does NOT re-prompt; the
        // native side does that transparently in production.
        expect(backend.writes, hasLength(1));
      },
    );

    test('read on a picker://<id> still routes to the picker bridge', () async {
      // Even on Android the picker://<id> path uses the
      // existing PickerFileBackend, NOT the SAF working-dir
      // backend. Verify by giving the channel a stub that
      // returns bytes for readPicker.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('agent_buddy/file'), (
            call,
          ) async {
            if (call.method == 'readPicker') {
              return Uint8List.fromList('picked'.codeUnits);
            }
            return null;
          });
      final got = await svc.read('picker://f-1', maxBytes: 4096);
      expect(String.fromCharCodes(got), 'picked');
      // Working-dir backend should NOT have been touched.
      expect(backend.reads, isEmpty);
    });
  });

  group('FileServiceImpl.pickWorkingDirectory', () {
    late _FakeWorkingDirBackend backend;
    late FileServiceImpl svc;

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('agent_buddy/file'),
            (call) async => null,
          );
      backend = _FakeWorkingDirBackend();
      svc = FileServiceImpl(
        workingDirectoryLookup: () => null,
        workingDirBackend: backend,
        isAndroid: true,
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('agent_buddy/file'),
            null,
          );
    });

    test('returns the (path, treeUri) pair from the backend', () async {
      backend.nextPickResult = (
        path: '/storage/emulated/0/Download/x',
        treeUri:
            'content://com.android.externalstorage.documents/tree/primary%3ADownload%2Fx',
      );
      final got = await svc.pickWorkingDirectory();
      expect(got, isNotNull);
      expect(got!.path, '/storage/emulated/0/Download/x');
      expect(got.treeUri, contains('content://'));
    });

    test('returns null when the user cancelled the picker', () async {
      backend.nextPickResult = null;
      final got = await svc.pickWorkingDirectory();
      expect(got, isNull);
    });
  });

  group('FileServiceImpl without a workingDirBackend (iOS path)', () {
    test('write/read on the working dir falls through to dart:io', () async {
      // The CI test runner is Linux; iOS branch is not
      // exercised here, but the constructor needs to
      // accept `isAndroid: false` and route through
      // dart:io. Pick a temp dir + write + read back.
      final dir = await Directory.systemTemp.createTemp('fs_no_backend_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final svc = FileServiceImpl(
        workingDirectoryLookup: () => dir.path,
        isAndroid: false,
      );
      await svc.write('hello.txt', 'hi'.codeUnits);
      final got = await svc.read('hello.txt');
      expect(String.fromCharCodes(got), 'hi');
    });
  });
}
