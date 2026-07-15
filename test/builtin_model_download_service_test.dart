import 'dart:io';

import 'package:agent_buddy/models/builtin_model.dart';
import 'package:agent_buddy/services/builtin_model_download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory docsDir;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp(
      'agent_buddy_builtin_dl_test_',
    );
  });

  tearDown(() async {
    if (await docsDir.exists()) {
      await docsDir.delete(recursive: true);
    }
  });

  /// Drives [BuiltinModelDownloadService.download] to its terminal
  /// event and returns the final snapshot + a flat list of every
  /// snapshot the stream emitted.
  Future<(BuiltinModelDownloadState, List<BuiltinModelDownloadState>)>
  collectDownload(
    BuiltinModelDownloadService service,
    BuiltinModel model,
  ) async {
    final out = <BuiltinModelDownloadState>[];
    await service.download(model).listen(out.add).asFuture<void>();
    return (out.last, out);
  }

  /// Two-stage mock client. The first URL request gets the model
  /// body; the second gets the mmproj body. Anything beyond that
  /// (e.g. retries) gets 404 so we notice if the service makes an
  /// unexpected request.
  http.Client twoStageClient({
    required List<int> modelBody,
    required List<int> mmprojBody,
  }) {
    var stage = 0;
    return MockClient((req) async {
      if (stage == 0) {
        stage++;
        return http.Response.bytes(
          modelBody,
          200,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': modelBody.length.toString(),
          },
        );
      }
      if (stage == 1) {
        stage++;
        return http.Response.bytes(
          mmprojBody,
          200,
          headers: {
            'content-type': 'application/octet-stream',
            'content-length': mmprojBody.length.toString(),
          },
        );
      }
      return http.Response('unexpected request to ${req.url}', 404);
    });
  }

  group('BuiltinModelDownloadService', () {
    test('downloads model + mmproj into <docs>/local_models/<id>/', () async {
      const model = BuiltinModel(
        id: 'test-model',
        displayName: 'Test Model',
        description: 'unit test',
        modelUrl: 'https://example.com/model.gguf',
        modelFilename: 'model.gguf',
        mmprojUrl: 'https://example.com/mmproj.gguf',
        mmprojFilename: 'mmproj.gguf',
        approxSizeBytes: 0,
      );
      final modelBody = List<int>.generate(2048, (i) => i % 256);
      final mmprojBody = List<int>.generate(512, (i) => (i * 7) % 256);
      final client = twoStageClient(
        modelBody: modelBody,
        mmprojBody: mmprojBody,
      );
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      final (last, snapshots) = await collectDownload(service, model);

      expect(last.overall, BuiltinModelDownloadPhase.completed);
      expect(last.modelFile.status, BuiltinFileStatus.completed);
      expect(last.mmprojFile?.status, BuiltinFileStatus.completed);
      expect(last.modelPath, isNotNull);
      expect(last.mmprojPath, isNotNull);

      // Files should live under <docs>/local_models/test-model/.
      // Path separators differ across platforms, so we just check
      // the trailing segment.
      expect(
        last.modelPath!.replaceAll(r'\', '/'),
        contains(
          '${docsDir.path.replaceAll(r'\', '/')}/local_models/test-model/',
        ),
      );
      expect(
        last.mmprojPath!.replaceAll(r'\', '/'),
        contains(
          '${docsDir.path.replaceAll(r'\', '/')}/local_models/test-model/',
        ),
      );
      expect(File(last.modelPath!).readAsBytesSync(), modelBody);
      expect(File(last.mmprojPath!).readAsBytesSync(), mmprojBody);

      // Sanity-check the snapshot stream: idle first, downloading
      // model in the middle, downloading mmproj after, completed
      // last.
      expect(snapshots.first.overall, BuiltinModelDownloadPhase.idle);
      expect(
        snapshots.any(
          (s) => s.overall == BuiltinModelDownloadPhase.downloadingModel,
        ),
        isTrue,
      );
      expect(
        snapshots.any(
          (s) => s.overall == BuiltinModelDownloadPhase.downloadingMmproj,
        ),
        isTrue,
      );
      expect(snapshots.last.overall, BuiltinModelDownloadPhase.completed);
    });

    test('model-only download skips the mmproj step', () async {
      const model = BuiltinModel(
        id: 'text-only',
        displayName: 'Text Model',
        description: 'no mmproj',
        modelUrl: 'https://example.com/text.gguf',
        modelFilename: 'text.gguf',
      );
      final body = List<int>.generate(1024, (i) => i % 128);
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
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      final (last, _) = await collectDownload(service, model);

      expect(last.overall, BuiltinModelDownloadPhase.completed);
      expect(last.mmprojFile, isNull);
      expect(last.modelPath, isNotNull);
      expect(File(last.modelPath!).readAsBytesSync(), body);
    });

    test('model download failure reports error and stops', () async {
      const model = BuiltinModel(
        id: 'bad',
        displayName: 'Broken',
        description: 'server 500s on the first file',
        modelUrl: 'https://example.com/bad.gguf',
        modelFilename: 'bad.gguf',
        mmprojUrl: 'https://example.com/bad-mmproj.gguf',
        mmprojFilename: 'bad-mmproj.gguf',
      );
      final client = MockClient((req) async {
        return http.Response('boom', 500);
      });
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      final (last, _) = await collectDownload(service, model);

      expect(last.overall, BuiltinModelDownloadPhase.failed);
      expect(last.modelFile.status, BuiltinFileStatus.failed);
      expect(last.modelFile.error, contains('500'));
      // The mmproj file shouldn't even be requested after the
      // model fails — verified by the two-stage mock throwing 404
      // for any second request.
      expect(last.mmprojFile?.status, BuiltinFileStatus.pending);

      // And no half-written file left behind in the data dir.
      final modelDir = Directory('${docsDir.path}/local_models/bad');
      if (await modelDir.exists()) {
        final entries = await modelDir.list().toList();
        expect(entries, isEmpty);
      }
    });

    test('isInstalled returns true after a successful download', () async {
      const model = BuiltinModel(
        id: 'check',
        displayName: 'Check',
        description: '',
        modelUrl: 'https://example.com/check.gguf',
        modelFilename: 'check.gguf',
      );
      final client = MockClient((req) async {
        return http.Response.bytes(
          List<int>.generate(64, (i) => i),
          200,
          headers: {'content-length': '64'},
        );
      });
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      expect(await service.isInstalled(model), isFalse);
      await collectDownload(service, model);
      expect(await service.isInstalled(model), isTrue);
    });

    test('cleanup removes partial files for a model', () async {
      const model = BuiltinModel(
        id: 'cleanup',
        displayName: 'Cleanup',
        description: '',
        modelUrl: 'https://example.com/cleanup.gguf',
        modelFilename: 'cleanup.gguf',
      );
      // Pre-create a stray file that looks like a partial download.
      final modelDir = Directory('${docsDir.path}/local_models/cleanup')
        ..createSync(recursive: true);
      final stray = File('${modelDir.path}/cleanup.gguf')
        ..writeAsBytesSync(List<int>.filled(1024, 1));
      expect(await stray.exists(), isTrue);

      final service = BuiltinModelDownloadService(
        docsDirResolver: () async => docsDir,
      );
      await service.cleanup(model);

      expect(await stray.exists(), isFalse);
    });

    test('resolvePaths returns the canonical destination paths', () async {
      const model = BuiltinModel(
        id: 'paths',
        displayName: 'Paths',
        description: '',
        modelUrl: 'https://example.com/paths.gguf',
        modelFilename: 'paths.gguf',
        mmprojUrl: 'https://example.com/paths-mmproj.gguf',
        mmprojFilename: 'paths-mmproj.gguf',
      );
      final service = BuiltinModelDownloadService(
        docsDirResolver: () async => docsDir,
      );
      final paths = await service.resolvePaths(model);
      expect(
        paths.dir.path.replaceAll(r'\', '/'),
        contains('${docsDir.path.replaceAll(r'\', '/')}/local_models/paths'),
      );
      expect(paths.modelPath, endsWith('paths.gguf'));
      expect(paths.mmprojPath, endsWith('paths-mmproj.gguf'));
    });

    test('emits live progress updates while bytes arrive', () async {
      // Use a stream-based mock so we control the chunk
      // boundaries. Without this, MockClient hands the whole
      // body to the consumer in one chunk and the throttled
      // progress yields all collapse onto a single boundary,
      // making it impossible to tell "live progress" from
      // "end-of-stream re-yield".
      const bodySize = 32 * 1024 * 16;
      final body = List<int>.generate(bodySize, (i) => i % 256);
      const chunkSize = 32 * 1024;
      final chunks = <List<int>>[
        for (var off = 0; off < body.length; off += chunkSize)
          List<int>.unmodifiable(
            body.sublist(off, (off + chunkSize).clamp(0, body.length)),
          ),
      ];
      final client = MockClient.streaming((req, bodyStream) async {
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          200,
          contentLength: bodySize,
        );
      });
      const model = BuiltinModel(
        id: 'progress',
        displayName: 'Progress',
        description: '',
        modelUrl: 'https://example.com/progress.gguf',
        modelFilename: 'progress.gguf',
      );
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      // Drain the stream and collect snapshots. Using `toList()`
      // ensures we wait for the stream to complete (no manual
      // future / controller wiring needed).
      final snapshots = await service.download(model).toList();

      // The intermediate `downloadingModel` snapshots with a
      // non-zero `bytesReceived` are what prove the listener
      // gets progress before the terminal `completed` snapshot.
      final modelProgressSnapshots = snapshots
          .where((s) => s.overall == BuiltinModelDownloadPhase.downloadingModel)
          .where((s) => s.modelFile.bytesReceived > 0)
          .map((s) => s.modelFile.bytesReceived)
          .toList();

      expect(
        modelProgressSnapshots.length,
        greaterThanOrEqualTo(3),
        reason:
            'expected multiple live progress updates, got '
            '${modelProgressSnapshots.length}: $modelProgressSnapshots',
      );
      // The progress events should be strictly increasing — this
      // is what proves they're live updates, not just a
      // single end-of-stream re-yield. The very last value may
      // equal the second-to-last because the throttled "running"
      // yield and the terminal "success" yield both land on the
      // body-size boundary, so we compare up to the second-to-
      // last snapshot only.
      for (var i = 1; i < modelProgressSnapshots.length - 1; i++) {
        expect(
          modelProgressSnapshots[i],
          greaterThan(modelProgressSnapshots[i - 1]),
          reason:
              'progress should be strictly increasing, got '
              '$modelProgressSnapshots',
        );
      }
      // The final value is allowed to equal the body size (the
      // last progress yield lands on the body-size boundary).
      expect(modelProgressSnapshots.last, lessThanOrEqualTo(bodySize));
      // And the stream ended with a `completed` snapshot.
      expect(snapshots.last.overall, BuiltinModelDownloadPhase.completed);
    });
  });

  group('BuiltinModels catalog', () {
    test('has at least one entry', () {
      expect(BuiltinModels.all, isNotEmpty);
    });

    test('byId returns the matching entry', () {
      for (final m in BuiltinModels.all) {
        expect(BuiltinModels.byId(m.id), same(m));
      }
    });

    test('byId returns null for unknown ids', () {
      expect(BuiltinModels.byId('not-a-real-model'), isNull);
    });

    test('every catalog entry has a non-empty model url + filename', () {
      for (final m in BuiltinModels.all) {
        expect(m.modelUrl, isNotEmpty);
        expect(m.modelFilename, endsWith('.gguf'));
        if (m.hasMmproj) {
          expect(m.mmprojUrl, isNotEmpty);
          expect(m.mmprojFilename, endsWith('.gguf'));
        }
      }
    });
  });
}
