import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/builtin_model.dart';

/// Per-file download progress for a built-in model. Mirrors the
/// shape of [DownloadItem] in spirit (bytes / total / status /
/// error / localPath) but lives in a separate type so the model
/// download path doesn't have to know about chat-bubble concerns.
class BuiltinFileDownload {
  const BuiltinFileDownload({
    required this.url,
    required this.filename,
    this.bytesReceived = 0,
    this.bytesTotal = -1,
    this.status = BuiltinFileStatus.pending,
    this.error,
    this.localPath,
  });

  final String url;
  final String filename;
  final int bytesReceived;
  final int bytesTotal;
  final BuiltinFileStatus status;
  final String? error;
  final String? localPath;

  double? get fraction {
    if (bytesTotal <= 0) return null;
    final f = bytesReceived / bytesTotal;
    if (f.isNaN || f.isInfinite) return null;
    return f.clamp(0.0, 1.0);
  }

  BuiltinFileDownload copyWith({
    int? bytesReceived,
    int? bytesTotal,
    BuiltinFileStatus? status,
    String? error,
    String? localPath,
  }) {
    return BuiltinFileDownload(
      url: url,
      filename: filename,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      status: status ?? this.status,
      error: error ?? this.error,
      localPath: localPath ?? this.localPath,
    );
  }
}

enum BuiltinFileStatus { pending, running, completed, failed, cancelled }

/// Top-level download state for a single built-in model. The
/// download page renders [model] / [mmproj] as two progress rows
/// and surfaces [overall] in the page header.
class BuiltinModelDownloadState {
  const BuiltinModelDownloadState({
    required this.model,
    required this.modelFile,
    required this.overall,
    this.mmprojFile,
  });

  final BuiltinModel model;
  final BuiltinFileDownload modelFile;
  final BuiltinFileDownload? mmprojFile;
  final BuiltinModelDownloadPhase overall;

  bool get isActive =>
      overall == BuiltinModelDownloadPhase.downloadingModel ||
      overall == BuiltinModelDownloadPhase.downloadingMmproj;

  bool get isTerminal =>
      overall == BuiltinModelDownloadPhase.completed ||
      overall == BuiltinModelDownloadPhase.failed ||
      overall == BuiltinModelDownloadPhase.cancelled;

  bool get isCompleted => overall == BuiltinModelDownloadPhase.completed;

  /// Local absolute paths the user can pass to [LocalProvider] when
  /// they hit save. `null` for any file that hasn't finished
  /// downloading.
  String? get modelPath => modelFile.status == BuiltinFileStatus.completed
      ? modelFile.localPath
      : null;
  String? get mmprojPath {
    final mp = mmprojFile;
    if (mp == null) return null;
    return mp.status == BuiltinFileStatus.completed ? mp.localPath : null;
  }

  BuiltinModelDownloadState copyWith({
    BuiltinFileDownload? modelFile,
    BuiltinFileDownload? mmprojFile,
    BuiltinModelDownloadPhase? overall,
  }) {
    return BuiltinModelDownloadState(
      model: model,
      modelFile: modelFile ?? this.modelFile,
      mmprojFile: mmprojFile ?? this.mmprojFile,
      overall: overall ?? this.overall,
    );
  }
}

enum BuiltinModelDownloadPhase {
  /// Not yet started. The model / mmproj rows are both `pending`.
  idle,

  /// Streaming the main model weights.
  downloadingModel,

  /// Streaming the mmproj (skipped if the model is text-only).
  downloadingMmproj,

  /// Both files have landed on disk.
  completed,

  /// One of the files failed. `modelFile.error` / `mmprojFile.error`
  /// carry the reason.
  failed,

  /// User cancelled mid-flight.
  cancelled,
}

/// Downloads a [BuiltinModel]'s weights (and optional mmproj) into
/// the app's documents directory and surfaces byte-level progress
/// to the settings page so the user can watch the bar fill up.
///
/// Files live in `<app docs>/local_models/<id>/<modelFilename>` and
/// `<app docs>/local_models/<id>/<mmprojFilename>`. The directory
/// layout matches what `LocalProvider` expects (a single folder
/// containing the model + projector side by side), so the rest of
/// the pipeline (auto-detect, hand-edit mmproj path) keeps working
/// unchanged.
class BuiltinModelDownloadService {
  BuiltinModelDownloadService({
    http.Client? httpClient,
    Future<Directory> Function()? docsDirResolver,
  }) : _client = httpClient ?? http.Client(),
       _docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory,
       _ownsClient = httpClient == null;

  final http.Client _client;
  final Future<Directory> Function() _docsDirResolver;
  final bool _ownsClient;

  final Map<String, _ActiveDownload> _active = {};

  /// Resolves the destination directory for [model] and creates it
  /// if needed. Lazy because we don't want to hit the platform
  /// channel for a directory the user may never visit.
  Future<Directory> _resolveModelDir(BuiltinModel model) async {
    final docs = await _docsDirResolver();
    final dir = Directory(p.join(docs.path, 'local_models', model.id));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns the destination directory + the absolute path the
  /// model weights would land in, even before the download starts.
  /// Used by the settings page to render the "Will be saved to ..."
  /// hint.
  Future<({Directory dir, String modelPath, String? mmprojPath})> resolvePaths(
    BuiltinModel model,
  ) async {
    final dir = await _resolveModelDir(model);
    final modelPath = p.join(dir.path, model.modelFilename);
    final mmprojPath = model.hasMmproj
        ? p.join(dir.path, model.mmprojFilename!)
        : null;
    return (dir: dir, modelPath: modelPath, mmprojPath: mmprojPath);
  }

  /// True when both the model and (if applicable) the mmproj file
  /// are already on disk and non-empty. The settings page uses this
  /// to render the "Downloaded" badge instead of the download
  /// button.
  Future<bool> isInstalled(BuiltinModel model) async {
    try {
      final paths = await resolvePaths(model);
      final modelFile = File(paths.modelPath);
      if (!await modelFile.exists()) return false;
      if (await modelFile.length() == 0) return false;
      if (model.hasMmproj) {
        final mmprojFile = File(paths.mmprojPath!);
        if (!await mmprojFile.exists()) return false;
        if (await mmprojFile.length() == 0) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts the download. Emits an initial `idle` snapshot so the
  /// UI can render the two rows before any bytes arrive, then a
  /// series of `running` snapshots with byte-level progress, and
  /// finally a terminal `completed` / `failed` / `cancelled`
  /// snapshot.
  ///
  /// Each `running` snapshot is emitted as soon as the underlying
  /// file stream yields a progress update (throttled to ~128 KB
  /// per update inside [_streamFile]). This is what drives the
  /// live progress bar in the download card.
  Stream<BuiltinModelDownloadState> download(BuiltinModel model) async* {
    final paths = await resolvePaths(model);
    final modelFile = BuiltinFileDownload(
      url: model.modelUrl,
      filename: model.modelFilename,
    );
    final mmprojFile = model.hasMmproj
        ? BuiltinFileDownload(
            url: model.mmprojUrl!,
            filename: model.mmprojFilename!,
          )
        : null;

    var cancelled = false;
    final active = _ActiveDownload(
      cancel: () {
        cancelled = true;
      },
    );
    _active[model.id] = active;

    var state = BuiltinModelDownloadState(
      model: model,
      modelFile: modelFile,
      mmprojFile: mmprojFile,
      overall: BuiltinModelDownloadPhase.idle,
    );
    yield state;

    try {
      // 1) Main model weights
      state = state.copyWith(
        overall: BuiltinModelDownloadPhase.downloadingModel,
        modelFile: modelFile.copyWith(
          status: BuiltinFileStatus.running,
          localPath: paths.modelPath,
        ),
      );
      yield state;

      var modelFailed = false;
      String? modelError;
      await for (final progress in _streamFile(
        url: model.modelUrl,
        destPath: paths.modelPath,
        cancelled: () => cancelled,
      )) {
        if (progress.cancelled) {
          state = state.copyWith(
            modelFile: state.modelFile.copyWith(
              status: BuiltinFileStatus.cancelled,
              error: 'cancelled',
            ),
            overall: BuiltinModelDownloadPhase.cancelled,
          );
          yield state;
          return;
        }
        if (progress.errorMessage != null) {
          modelFailed = true;
          modelError = progress.errorMessage;
          break;
        }
        if (progress.success) {
          state = state.copyWith(
            modelFile: state.modelFile.copyWith(
              bytesReceived: progress.bytesReceived,
              bytesTotal: progress.bytesTotal,
              status: BuiltinFileStatus.completed,
              localPath: paths.modelPath,
            ),
          );
          yield state;
          break;
        }
        // Live progress update — this is what drives the bar.
        state = state.copyWith(
          modelFile: state.modelFile.copyWith(
            bytesReceived: progress.bytesReceived,
            bytesTotal: progress.bytesTotal,
          ),
        );
        yield state;
      }
      if (modelFailed) {
        state = state.copyWith(
          modelFile: state.modelFile.copyWith(
            status: BuiltinFileStatus.failed,
            error: modelError ?? 'download failed',
          ),
          overall: BuiltinModelDownloadPhase.failed,
        );
        yield state;
        return;
      }

      // 2) mmproj (if any)
      if (model.hasMmproj && mmprojFile != null) {
        state = state.copyWith(
          overall: BuiltinModelDownloadPhase.downloadingMmproj,
          mmprojFile: mmprojFile.copyWith(
            status: BuiltinFileStatus.running,
            localPath: paths.mmprojPath,
          ),
        );
        yield state;

        var mmprojFailed = false;
        String? mmprojError;
        await for (final progress in _streamFile(
          url: model.mmprojUrl!,
          destPath: paths.mmprojPath!,
          cancelled: () => cancelled,
        )) {
          if (progress.cancelled) {
            state = state.copyWith(
              mmprojFile: state.mmprojFile!.copyWith(
                status: BuiltinFileStatus.cancelled,
                error: 'cancelled',
              ),
              overall: BuiltinModelDownloadPhase.cancelled,
            );
            yield state;
            return;
          }
          if (progress.errorMessage != null) {
            mmprojFailed = true;
            mmprojError = progress.errorMessage;
            break;
          }
          if (progress.success) {
            state = state.copyWith(
              mmprojFile: state.mmprojFile!.copyWith(
                bytesReceived: progress.bytesReceived,
                bytesTotal: progress.bytesTotal,
                status: BuiltinFileStatus.completed,
                localPath: paths.mmprojPath,
              ),
            );
            yield state;
            break;
          }
          state = state.copyWith(
            mmprojFile: state.mmprojFile!.copyWith(
              bytesReceived: progress.bytesReceived,
              bytesTotal: progress.bytesTotal,
            ),
          );
          yield state;
        }
        if (mmprojFailed) {
          state = state.copyWith(
            mmprojFile: state.mmprojFile!.copyWith(
              status: BuiltinFileStatus.failed,
              error: mmprojError ?? 'download failed',
            ),
            overall: BuiltinModelDownloadPhase.failed,
          );
          yield state;
          return;
        }
      }

      state = state.copyWith(overall: BuiltinModelDownloadPhase.completed);
      yield state;
    } finally {
      _active.remove(model.id);
    }
  }

  /// Cancels an in-flight download by built-in model id. Safe to
  /// call multiple times and safe to call after the download has
  /// already finished (no-op in that case).
  void cancel(String modelId) {
    final active = _active[modelId];
    if (active != null) active.cancel();
  }

  /// Best-effort cleanup of partial files for [model]. Called when
  /// the user backs out of the download page mid-flight so we
  /// don't leave a half-written GGUF in the data dir.
  Future<void> cleanup(BuiltinModel model) async {
    cancel(model.id);
    try {
      final paths = await resolvePaths(model);
      for (final path in [paths.modelPath, paths.mmprojPath]) {
        if (path == null) continue;
        final f = File(path);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Best-effort. If the platform refuses, the next download
      // overwrites the file anyway.
    }
  }

  /// Streams `url` to `destPath`. Yields [_FileProgress] events as
  /// bytes arrive (throttled to one update per ~128 KB so the UI
  /// doesn't drown in notifications on a 1.7 GB model). Terminal
  /// result is communicated via the final [_FileProgress.success]
  /// flag (or [BuiltinFileDownloadState]'s `failed` / `cancelled`
  /// phase when the consumer is structured to read it from there).
  ///
  /// Cancellation is signalled via the `cancelled` callback —
  /// the consumer's [BuiltinModelDownloadState.overall] flips to
  /// `cancelled` and the partial file is removed.
  Stream<_FileProgress> _streamFile({
    required String url,
    required String destPath,
    required bool Function() cancelled,
  }) async* {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      yield _FileProgress.failure('invalid URL: $url');
      return;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      yield _FileProgress.failure('only http(s) URLs are supported: $url');
      return;
    }
    final file = File(destPath);
    final sink = file.openWrite();
    var bytesReceived = 0;
    var bytesTotal = -1;
    try {
      final req = http.Request('GET', uri);
      req.headers['User-Agent'] =
          'Mozilla/5.0 (compatible; AgentBuddy/1.0; +https://agent.buddy)';
      final response = await _client.send(req);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.drain<void>().catchError((_) {});
        await _disposeSink(sink, file);
        yield _FileProgress.failure('HTTP ${response.statusCode}');
        return;
      }
      final cl = response.contentLength;
      if (cl != null && cl >= 0) bytesTotal = cl;
      yield _FileProgress(bytesReceived: 0, bytesTotal: bytesTotal);

      // 32 KB buffer — same trade-off as the chat download service:
      // big enough to amortize writes, small enough for smooth
      // progress repaints.
      const chunkSize = 32 * 1024;
      final stream = response.stream;
      await for (final chunk in stream.handleError((Object e, StackTrace s) {
        if (cancelled()) return;
        throw e;
      })) {
        if (cancelled()) break;
        if (chunk.isEmpty) continue;
        sink.add(chunk);
        bytesReceived += chunk.length;
        // Throttle: yield progress every 128 KB worth of bytes
        // (4 × chunkSize). The settings page repaints frequently
        // enough that per-chunk updates would just stall the UI on
        // a 1.7 GB model.
        if (bytesReceived % (chunkSize * 4) < chunkSize) {
          yield _FileProgress(
            bytesReceived: bytesReceived,
            bytesTotal: bytesTotal,
          );
        }
        if (cancelled()) break;
      }
      if (bytesTotal < 0) bytesTotal = bytesReceived;

      if (cancelled()) {
        await _disposeSink(sink, file);
        yield _FileProgress.cancelled();
        return;
      }
      if (bytesReceived == 0) {
        await _disposeSink(sink, file);
        yield _FileProgress.failure('empty response');
        return;
      }
      await sink.flush();
      await sink.close();
      yield _FileProgress(
        bytesReceived: bytesReceived,
        bytesTotal: bytesTotal,
        success: true,
      );
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      yield _FileProgress.failure(e.toString());
    }
  }

  /// Best-effort sink close + file delete. Used by [_streamFile]
  /// when bailing out before the happy path.
  Future<void> _disposeSink(IOSink sink, File file) async {
    try {
      await sink.close();
    } catch (_) {}
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class _ActiveDownload {
  _ActiveDownload({required this.cancel});
  final void Function() cancel;
}

/// One event emitted by [_streamFile]. `bytesReceived` /
/// `bytesTotal` carry the running counters; exactly one of
/// `success` / `cancelled` / `errorMessage` is non-null on the
/// terminal event (and all are null on intermediate progress
/// updates).
class _FileProgress {
  const _FileProgress({
    required this.bytesReceived,
    required this.bytesTotal,
    this.success = false,
    this.cancelled = false,
    this.errorMessage,
  });
  factory _FileProgress.failure(String error) =>
      _FileProgress(bytesReceived: 0, bytesTotal: -1, errorMessage: error);
  factory _FileProgress.cancelled() =>
      const _FileProgress(bytesReceived: 0, bytesTotal: -1, cancelled: true);

  final int bytesReceived;
  final int bytesTotal;
  final bool success;
  final bool cancelled;
  final String? errorMessage;
}
