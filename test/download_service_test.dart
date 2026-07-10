import 'dart:async';
import 'dart:io';

import 'package:agent_buddy/models/download.dart';
import 'package:agent_buddy/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_dl_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Drives [DownloadService.download] to its terminal event and
  /// returns the final [DownloadItem] + a flat list of every
  /// snapshot the stream emitted.
  Future<(DownloadItem, List<DownloadItem>)> collectDownload(
    DownloadService service, {
    required String url,
    String? filename,
    String? downloadId,
  }) async {
    final out = <DownloadItem>[];
    DownloadItem? last;
    await service
        .download(
          url: url,
          filename: filename,
          downloadId: downloadId ?? 'dl_test_id',
        )
        .listen(out.add)
        .asFuture<void>();
    last = out.last;
    return (last, out);
  }

  group('DownloadService.download', () {
    test('writes a file to the temp dir and reports progress', () async {
      final body = List<int>.generate(2048, (i) => i % 256);
      final client = MockClient((req) async {
        return http.Response.bytes(
          body,
          200,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': body.length.toString(),
          },
        );
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);

      final (last, snapshots) = await collectDownload(
        service,
        url: 'https://example.com/file.bin',
      );

      expect(last.status, DownloadStatus.completed);
      expect(last.bytesReceived, body.length);
      expect(last.bytesTotal, body.length);
      expect(last.localPath, isNotNull);
      final file = File(last.localPath!);
      expect(await file.exists(), isTrue);
      final written = await file.readAsBytes();
      expect(written, body);

      // The stream should have emitted a `pending` snapshot, one
      // or more `running` snapshots, and a final `completed` one.
      expect(snapshots.first.status, DownloadStatus.pending);
      expect(snapshots.any((s) => s.status == DownloadStatus.running), isTrue);
      expect(snapshots.last.status, DownloadStatus.completed);
    });

    test('rejects non-http(s) schemes', () async {
      final service = DownloadService(tempDir: tempDir);
      // [DownloadService.download] is an async* generator, so
      // the URL validation throws lazily — the error is
      // surfaced on the stream, not as a returned Future.
      await expectLater(
        service
            .download(url: 'file:///etc/passwd', downloadId: 'dl_1')
            .toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('rejects empty / malformed URLs', () async {
      final service = DownloadService(tempDir: tempDir);
      await expectLater(
        service.download(url: '', downloadId: 'dl_1').toList(),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        service.download(url: 'not a url', downloadId: 'dl_1').toList(),
        throwsA(isA<Exception>()),
      );
    });

    test('HTTP 4xx is reported as a `failed` snapshot', () async {
      final client = MockClient((req) async {
        return http.Response('not found', 404);
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);

      final (last, snapshots) = await collectDownload(
        service,
        url: 'https://example.com/missing',
      );

      expect(last.status, DownloadStatus.failed);
      expect(last.error, contains('404'));
      // Failed downloads should NOT leave a half-written file
      // behind in the temp dir.
      final downloads = Directory('${tempDir.path}/downloads');
      if (await downloads.exists()) {
        final entries = await downloads.list().toList();
        expect(entries, isEmpty);
      }
      // First snapshot is still `pending` so the UI can render
      // a placeholder row.
      expect(snapshots.first.status, DownloadStatus.pending);
    });

    test('honors a Content-Disposition filename when the caller '
        'doesn\'t pin one', () async {
      final client = MockClient((req) async {
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {
            'content-type': 'image/png',
            'content-disposition': 'attachment; filename="hello.png"',
          },
        );
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);

      final (last, _) = await collectDownload(
        service,
        url: 'https://example.com/x',
      );

      expect(last.status, DownloadStatus.completed);
      expect(last.filename, 'hello.png');
    });

    test('prefers an explicit filename over the URL path', () async {
      final client = MockClient((req) async {
        return http.Response.bytes([0], 200);
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (last, _) = await collectDownload(
        service,
        url: 'https://example.com/wrong.bin',
        filename: 'right.bin',
      );
      expect(last.filename, 'right.bin');
    });

    test(
      'derives a filename from the URL when nothing else is given',
      () async {
        final client = MockClient((req) async {
          return http.Response.bytes([0], 200);
        });
        final service = DownloadService(httpClient: client, tempDir: tempDir);
        final (last, _) = await collectDownload(
          service,
          url: 'https://example.com/path/to/photo.jpg',
        );
        expect(last.filename, 'photo.jpg');
      },
    );

    test('fallback filename for URL without an extension is a '
        'millisecond-stamped generic', () async {
      final client = MockClient((req) async {
        return http.Response.bytes([0], 200);
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (last, _) = await collectDownload(
        service,
        url: 'https://example.com/api/v1/items',
      );
      expect(last.filename, startsWith('download_'));
    });

    test('sanitizes path separators in the supplied filename', () async {
      final client = MockClient((req) async {
        return http.Response.bytes([0], 200);
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (last, _) = await collectDownload(
        service,
        url: 'https://example.com/x',
        filename: '../../etc/passwd',
      );
      // Path traversal segments are dropped / replaced with `_`.
      expect(last.filename.contains('/'), isFalse);
      expect(last.filename.contains('\\'), isFalse);
    });

    test('cancel() stops an in-flight download', () async {
      // Build a response that yields bytes in a few chunks with
      // a long enough gap that we can race cancel() against it.
      final c = Completer<void>();
      final client = MockClient.streaming((req, bodyStream) async {
        final stream =
            Stream.fromIterable([
              List<int>.filled(64, 1),
              List<int>.filled(64, 2),
              List<int>.filled(64, 3),
            ]).asyncMap((chunk) async {
              await c.future.timeout(
                const Duration(milliseconds: 10),
                onTimeout: () {},
              );
              return chunk;
            });
        return http.StreamedResponse(
          stream,
          200,
          contentLength: 192,
          headers: {'content-type': 'application/octet-stream'},
        );
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);

      final snapshots = <DownloadItem>[];
      final sub = service
          .download(url: 'https://example.com/big.bin', downloadId: 'dl_cancel')
          .listen(snapshots.add);
      // Let a chunk or two land, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      service.cancel('dl_cancel');
      await sub.asFuture<void>();
      c.complete();

      expect(snapshots.last.status, DownloadStatus.cancelled);
      // Temp file should be cleaned up on cancel.
      final downloads = Directory('${tempDir.path}/downloads');
      if (await downloads.exists()) {
        final entries = await downloads.list().toList();
        expect(entries, isEmpty);
      }
    });
  });

  group('DownloadService.saveTo', () {
    test('copies the temp file to the destination and deletes the '
        'temp file', () async {
      final body = [1, 2, 3, 4, 5];
      final client = MockClient((req) async {
        return http.Response.bytes(body, 200);
      });
      final destDir = await tempDir.createTemp('dest_');
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (item, _) = await collectDownload(
        service,
        url: 'https://example.com/x',
        filename: 'photo.png',
      );

      final savedPath = await service.saveTo(item: item, destDir: destDir.path);
      expect(savedPath, endsWith('photo.png'));
      final saved = File(savedPath);
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsBytes(), body);
      // Temp file is gone.
      expect(await File(item.localPath!).exists(), isFalse);
    });

    test(
      'picks a non-clashing path when the target name already exists',
      () async {
        final body = [1, 2, 3];
        final client = MockClient((req) async {
          return http.Response.bytes(body, 200);
        });
        final destDir = await tempDir.createTemp('dest_');
        // Pre-create the conflict.
        await File('${destDir.path}/photo.png').writeAsBytes([9, 9, 9]);
        final service = DownloadService(httpClient: client, tempDir: tempDir);
        final (item, _) = await collectDownload(
          service,
          url: 'https://example.com/x',
          filename: 'photo.png',
        );
        final savedPath = await service.saveTo(
          item: item,
          destDir: destDir.path,
        );
        expect(savedPath, endsWith('photo (1).png'));
        // Original file is untouched.
        final original = File('${destDir.path}/photo.png');
        expect(await original.readAsBytes(), [9, 9, 9]);
        final newOne = File(savedPath);
        expect(await newOne.readAsBytes(), body);
      },
    );

    test('throws when the temp file is gone (e.g. app restart)', () async {
      final client = MockClient((req) async {
        return http.Response.bytes([1], 200);
      });
      final destDir = await tempDir.createTemp('dest_');
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (item, _) = await collectDownload(
        service,
        url: 'https://example.com/x',
      );
      // Simulate app restart wiping the temp dir.
      await tempDir.delete(recursive: true);
      await expectLater(
        service.saveTo(item: item, destDir: destDir.path),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('DownloadService.cleanup', () {
    test('deletes the temp file behind a completed download', () async {
      final client = MockClient((req) async {
        return http.Response.bytes([1, 2, 3], 200);
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (item, _) = await collectDownload(
        service,
        url: 'https://example.com/x',
      );
      expect(await File(item.localPath!).exists(), isTrue);
      await service.cleanup(item);
      expect(await File(item.localPath!).exists(), isFalse);
    });

    test('is a no-op when the file is already gone', () async {
      final client = MockClient((req) async {
        return http.Response.bytes([1], 200);
      });
      final service = DownloadService(httpClient: client, tempDir: tempDir);
      final (item, _) = await collectDownload(
        service,
        url: 'https://example.com/x',
      );
      // Manually delete first.
      await File(item.localPath!).delete();
      // Second cleanup must not throw.
      await service.cleanup(item);
    });
  });

  group('DownloadItem', () {
    test('roundtrips through toJson / fromJson', () {
      final item = DownloadItem(
        id: 'd1',
        url: 'https://example.com/x',
        filename: 'a.bin',
        bytesReceived: 100,
        bytesTotal: 200,
        status: DownloadStatus.running,
        contentType: 'application/octet-stream',
      );
      final raw = item.toRawJson();
      final back = DownloadItem.fromRawJson(raw);
      expect(back.id, item.id);
      expect(back.url, item.url);
      expect(back.filename, item.filename);
      expect(back.bytesReceived, item.bytesReceived);
      expect(back.bytesTotal, item.bytesTotal);
      expect(back.status, item.status);
      expect(back.contentType, item.contentType);
    });

    test('fraction is null when bytesTotal is unknown', () {
      final item = DownloadItem(
        id: 'd1',
        url: 'x',
        filename: 'x',
        bytesReceived: 50,
        bytesTotal: -1,
      );
      expect(item.fraction, isNull);
    });

    test('fraction clamps to [0, 1]', () {
      final item = DownloadItem(
        id: 'd1',
        url: 'x',
        filename: 'x',
        bytesReceived: 150,
        bytesTotal: 100,
      );
      expect(item.fraction, 1.0);
    });
  });
}
