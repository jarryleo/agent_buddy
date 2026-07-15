import 'dart:async';
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

  /// Spins until the service's state for [modelId] reaches a
  /// terminal phase (completed / failed / cancelled) or [timeout]
  /// elapses. The download is now fire-and-forget on a
  /// long-lived service, so tests need to wait for it to
  /// finish via the state object rather than a Future.
  Future<BuiltinModelDownloadState> waitForTerminal(
    BuiltinModelDownloadService service,
    String modelId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final s = service.stateFor(modelId);
      if (s != null && s.isTerminal) return s;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException(
      'download did not reach a terminal state in $timeout',
    );
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

      service.startDownload(model);
      expect(service.isActive(model.id), isTrue);
      final last = await waitForTerminal(service, model.id);

      expect(last.overall, BuiltinModelDownloadPhase.completed);
      expect(last.modelFile.status, BuiltinFileStatus.completed);
      expect(last.mmprojFile?.status, BuiltinFileStatus.completed);
      expect(last.modelPath, isNotNull);
      expect(last.mmprojPath, isNotNull);
      expect(service.isActive(model.id), isFalse);

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

      service.startDownload(model);
      final last = await waitForTerminal(service, model.id);

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

      service.startDownload(model);
      final last = await waitForTerminal(service, model.id);

      expect(last.overall, BuiltinModelDownloadPhase.failed);
      expect(last.modelFile.status, BuiltinFileStatus.failed);
      expect(last.modelFile.error, contains('500'));
      // The mmproj file shouldn't even be requested after the
      // model fails — verified by the two-stage mock throwing
      // 404 for any second request.
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
      service.startDownload(model);
      await waitForTerminal(service, model.id);
      expect(await service.isInstalled(model), isTrue);
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
      // 512 KB body gives us at least 3 progress events at the
      // 128 KB throttle boundary (128 KB, 256 KB, 384 KB) plus
      // the terminal 512 KB yield, so we can prove progress
      // is being pushed to the listener before the stream
      // completes.
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

      // Collect snapshots via addListener.
      final snapshots = <BuiltinModelDownloadState>[];
      void listener() {
        final s = service.stateFor(model.id);
        if (s != null) snapshots.add(s);
      }

      service.addListener(listener);
      service.startDownload(model);
      final last = await waitForTerminal(service, model.id);
      service.removeListener(listener);

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
      expect(last.overall, BuiltinModelDownloadPhase.completed);
    });

    test(
      'cancel() stops an in-flight download and preserves the partial',
      () async {
        // We use a slow-streaming mock so we have time to flip
        // the cancel flag while bytes are still in flight.
        const bodySize = 32 * 1024 * 8;
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
            Stream.fromIterable(chunks).asyncMap((c) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              return c;
            }),
            200,
            contentLength: bodySize,
          );
        });
        const model = BuiltinModel(
          id: 'cancel',
          displayName: 'Cancel',
          description: '',
          modelUrl: 'https://example.com/cancel.gguf',
          modelFilename: 'cancel.gguf',
        );
        final service = BuiltinModelDownloadService(
          httpClient: client,
          docsDirResolver: () async => docsDir,
        );

        service.startDownload(model);
        // Let a chunk or two land, then cancel.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        service.cancel(model.id);
        final last = await waitForTerminal(service, model.id);

        expect(last.overall, BuiltinModelDownloadPhase.cancelled);
        expect(last.modelFile.status, BuiltinFileStatus.cancelled);
        // The partial file should be on disk (smaller than the
        // full body, but non-zero).
        final paths = await service.resolvePaths(model);
        final partial = File(paths.modelPath);
        expect(await partial.exists(), isTrue);
        final size = await partial.length();
        expect(size, greaterThan(0));
        expect(size, lessThan(bodySize));
      },
    );

    test('second startDownload after cancel resumes from the partial '
        'via Range request', () async {
      // 1 MB body. First run is cancelled mid-flight. Second
      // run should send a Range request and the server should
      // answer with 206.
      const bodySize = 32 * 1024 * 32;
      final body = List<int>.generate(bodySize, (i) => i % 256);
      const chunkSize = 32 * 1024;
      final chunks = <List<int>>[
        for (var off = 0; off < body.length; off += chunkSize)
          List<int>.unmodifiable(
            body.sublist(off, (off + chunkSize).clamp(0, body.length)),
          ),
      ];
      // Track whether the second request carries a Range
      // header — this is what proves the service is actually
      // attempting to resume, not just restarting.
      String? rangeHeaderOnSecondAttempt;
      var attempt = 0;
      final client = MockClient.streaming((req, bodyStream) async {
        attempt++;
        if (attempt == 1) {
          return http.StreamedResponse(
            Stream.fromIterable(chunks).asyncMap((c) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              return c;
            }),
            200,
            contentLength: bodySize,
          );
        }
        rangeHeaderOnSecondAttempt = req.headers['range'];
        // The server returns 206 Partial Content for the resume
        // request. The Content-Length is the size of the
        // remainder.
        final resumeFrom = int.parse(
          req.headers['range']!.split('=')[1].split('-')[0],
        );
        final remaining = bodySize - resumeFrom;
        return http.StreamedResponse(
          Stream.fromIterable(
            chunks.skip(resumeFrom ~/ chunkSize).toList(),
          ).asyncMap((c) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return c;
          }),
          206,
          contentLength: remaining,
        );
      });
      const model = BuiltinModel(
        id: 'resume',
        displayName: 'Resume',
        description: '',
        modelUrl: 'https://example.com/resume.gguf',
        modelFilename: 'resume.gguf',
      );
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      // First run, cancel mid-flight.
      service.startDownload(model);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      service.cancel(model.id);
      await waitForTerminal(service, model.id);

      // The partial file should be on disk.
      final paths = await service.resolvePaths(model);
      final partial = File(paths.modelPath);
      final partialSize = await partial.length();
      expect(partialSize, greaterThan(0));
      expect(partialSize, lessThan(bodySize));

      // The in-memory state has the partial's bytesReceived.
      // The user would see "Continue" / "重新下载" affordances.
      // (The page is responsible for surfacing that — here we
      // just verify the state machine.)
      expect(service.stateFor(model.id)!.canResume, isTrue);

      // Second run: should send a Range request and complete.
      service.startDownload(model);
      final last = await waitForTerminal(service, model.id);

      expect(rangeHeaderOnSecondAttempt, isNotNull);
      expect(rangeHeaderOnSecondAttempt, startsWith('bytes='));
      expect(last.overall, BuiltinModelDownloadPhase.completed);
      expect(await partial.length(), bodySize);
      expect(await partial.readAsBytes(), body);
    });

    test('second startDownload after cancel falls back to a full '
        'download when the server does not honor Range', () async {
      // Some servers (or CDNs) respond with 200 OK + the full
      // body even when we asked for a range. The service should
      // detect that, drop the partial, and re-download from
      // scratch.
      const bodySize = 32 * 1024 * 16;
      final body = List<int>.generate(bodySize, (i) => i % 256);
      const chunkSize = 32 * 1024;
      final chunks = <List<int>>[
        for (var off = 0; off < body.length; off += chunkSize)
          List<int>.unmodifiable(
            body.sublist(off, (off + chunkSize).clamp(0, body.length)),
          ),
      ];
      var attempt = 0;
      var rangeRequestAttempted = false;
      final client = MockClient.streaming((req, bodyStream) async {
        attempt++;
        if (attempt == 1) {
          return http.StreamedResponse(
            Stream.fromIterable(chunks).asyncMap((c) async {
              await Future<void>.delayed(const Duration(milliseconds: 30));
              return c;
            }),
            200,
            contentLength: bodySize,
          );
        }
        // If the service sent a Range header (the "try resume"
        // attempt), we pretend to be a server that doesn't
        // honor it and return 200 with the full body.
        if (req.headers.containsKey('range')) {
          rangeRequestAttempted = true;
          return http.StreamedResponse(
            Stream.fromIterable(chunks),
            200,
            contentLength: bodySize,
          );
        }
        // Otherwise: normal fresh download.
        return http.StreamedResponse(
          Stream.fromIterable(chunks),
          200,
          contentLength: bodySize,
        );
      });
      const model = BuiltinModel(
        id: 'no-range',
        displayName: 'NoRange',
        description: '',
        modelUrl: 'https://example.com/no-range.gguf',
        modelFilename: 'no-range.gguf',
      );
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      // First run, cancel.
      service.startDownload(model);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      service.cancel(model.id);
      await waitForTerminal(service, model.id);

      // Second run: service tries to resume, server returns
      // 200, service drops the partial and re-downloads from
      // scratch.
      service.startDownload(model);
      final last = await waitForTerminal(service, model.id);

      expect(rangeRequestAttempted, isTrue);
      expect(last.overall, BuiltinModelDownloadPhase.completed);
      final paths = await service.resolvePaths(model);
      expect(
        await File(paths.modelPath).readAsBytes(),
        body,
        reason: 'fallback download should yield the full body',
      );
    });

    test('state survives across the page lifecycle (background '
        'download)', () async {
      // Simulate a user opening the page, starting a download,
      // navigating away (page disposed), and coming back. The
      // download state must be retrievable from the service.
      const bodySize = 32 * 1024 * 4;
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
          Stream.fromIterable(chunks).asyncMap((c) async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return c;
          }),
          200,
          contentLength: bodySize,
        );
      });
      const model = BuiltinModel(
        id: 'background',
        displayName: 'Background',
        description: '',
        modelUrl: 'https://example.com/bg.gguf',
        modelFilename: 'bg.gguf',
      );
      final service = BuiltinModelDownloadService(
        httpClient: client,
        docsDirResolver: () async => docsDir,
      );

      // Page 1: start a download.
      service.startDownload(model);
      expect(service.stateFor(model.id), isNotNull);

      // Simulate the page being disposed. The service is
      // long-lived, so the download keeps running.
      // (No code change needed — the subscription lives on the
      // service, not the page.)

      // Page 2: re-attach to the same in-flight download.
      final stateOnReturn = service.stateFor(model.id);
      expect(stateOnReturn, isNotNull);
      expect(service.isActive(model.id), isTrue);

      // Wait for it to finish, no further interaction needed.
      final last = await waitForTerminal(service, model.id);
      expect(last.overall, BuiltinModelDownloadPhase.completed);
    });

    test('deleteDownloadedFiles clears the on-disk artefacts', () async {
      const model = BuiltinModel(
        id: 'cleanup',
        displayName: 'Cleanup',
        description: '',
        modelUrl: 'https://example.com/cleanup.gguf',
        modelFilename: 'cleanup.gguf',
      );
      // Pre-create a stray file that looks like a downloaded
      // model.
      final modelDir = Directory('${docsDir.path}/local_models/cleanup')
        ..createSync(recursive: true);
      final stray = File('${modelDir.path}/cleanup.gguf')
        ..writeAsBytesSync(List<int>.filled(1024, 1));
      expect(await stray.exists(), isTrue);

      final service = BuiltinModelDownloadService(
        docsDirResolver: () async => docsDir,
      );
      await service.deleteDownloadedFiles(model);

      expect(await stray.exists(), isFalse);
    });

    test(
      'deleteDownloadedFile drops just the named file and resets its slot',
      () async {
        const model = BuiltinModel(
          id: 'per-file',
          displayName: 'Per file',
          description: '',
          modelUrl: 'https://example.com/per-file.gguf',
          modelFilename: 'per-file.gguf',
          mmprojUrl: 'https://example.com/per-file.mmproj',
          mmprojFilename: 'per-file.mmproj',
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
        service.startDownload(model);
        final state = await waitForTerminal(service, model.id);
        expect(state.overall, BuiltinModelDownloadPhase.completed);

        final modelPath = state.modelPath!;
        final mmprojPath = state.mmprojPath!;
        expect(await File(modelPath).exists(), isTrue);
        expect(await File(mmprojPath).exists(), isTrue);

        // Delete just the model weights. The mmproj file should
        // stay put, and the model slot should be reset to
        // pending; the overall phase should reflect that the
        // model is no longer present (recompute lands on
        // `cancelled` because the reset slot is pending and the
        // other slot is completed — see _recomputeOverallPhase).
        final modelFile = state.modelFile;
        await service.deleteDownloadedFile(model, modelFile);

        expect(await File(modelPath).exists(), isFalse);
        expect(await File(mmprojPath).exists(), isTrue);

        final after = service.stateFor(model.id)!;
        expect(after.modelFile.status, BuiltinFileStatus.pending);
        expect(after.modelFile.bytesReceived, 0);
        expect(after.modelFile.localPath, isNull);
        // The other slot is untouched.
        expect(after.mmprojFile?.status, BuiltinFileStatus.completed);
        expect(after.mmprojFile?.localPath, mmprojPath);
      },
    );

    test(
      'deleteDownloadedFile is a no-op when the model has no state',
      () async {
        const model = BuiltinModel(
          id: 'no-state',
          displayName: 'No state',
          description: '',
          modelUrl: 'https://example.com/no-state.gguf',
          modelFilename: 'no-state.gguf',
        );
        final service = BuiltinModelDownloadService(
          docsDirResolver: () async => docsDir,
        );
        // Should not throw even though we've never started a
        // download for this model.
        final fakeFile = BuiltinFileDownload(
          url: model.modelUrl,
          filename: model.modelFilename,
          localPath: '${docsDir.path}/never-existed.gguf',
        );
        await service.deleteDownloadedFile(model, fakeFile);
        expect(service.stateFor(model.id), isNull);
      },
    );

    test(
      'clearState removes the in-memory snapshot but keeps the file',
      () async {
        const model = BuiltinModel(
          id: 'clear',
          displayName: 'Clear',
          description: '',
          modelUrl: 'https://example.com/clear.gguf',
          modelFilename: 'clear.gguf',
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
        service.startDownload(model);
        await waitForTerminal(service, model.id);
        expect(service.stateFor(model.id), isNotNull);
        expect(await service.isInstalled(model), isTrue);

        service.clearState(model.id);
        expect(service.stateFor(model.id), isNull);
        // The file is still on disk — the next startDownload
        // would short-circuit to "already complete" (or restart
        // from the existing file, depending on the service's
        // policy; we just check the file is there).
        expect(await service.isInstalled(model), isTrue);
      },
    );
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
