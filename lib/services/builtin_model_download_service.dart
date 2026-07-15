import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  /// True when the file on disk is non-empty (i.e. there's
  /// something to resume from). `false` on web / when path
  /// resolution failed.
  bool get hasPartial =>
      bytesReceived > 0 && status != BuiltinFileStatus.completed;

  /// 0.0 → 1.0. Falls back to indeterminate when the server
  /// didn't send a Content-Length.
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
  bool get isFailed => overall == BuiltinModelDownloadPhase.failed;
  bool get isCancelled => overall == BuiltinModelDownloadPhase.cancelled;

  /// True if the user cancelled (or the download failed) AND
  /// there's still a partial file on disk worth resuming.
  bool get canResume {
    if (overall != BuiltinModelDownloadPhase.cancelled &&
        overall != BuiltinModelDownloadPhase.failed) {
      return false;
    }
    if (modelFile.hasPartial) return true;
    final mp = mmprojFile;
    if (mp != null && mp.hasPartial) return true;
    return false;
  }

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
  /// carry the reason. A partial file may still exist on disk —
  /// the user can resume.
  failed,

  /// User cancelled mid-flight. A partial file may still exist on
  /// disk — the user can resume.
  cancelled,
}

/// Long-lived download service for built-in models.
///
/// The service is provided via DI in `main.dart` and stays alive
/// for the lifetime of the app. This is what enables **background
/// downloads**: a download started on the settings page continues
/// even after the user navigates away. The page re-attaches to the
/// in-flight download by calling [stateFor] when it's re-opened.
///
/// Each download is identified by [BuiltinModel.id]. At most one
/// download per model can be active at a time — calling
/// [startDownload] for a model that's already downloading is a
/// no-op. The actual HTTP transfer is **resumable**: if a partial
/// file is on disk (from a previous cancel / app kill / failed
/// download), the next [startDownload] sends a `Range: bytes=N-`
/// header and the server is expected to respond with
/// `206 Partial Content`. Servers that don't support range
/// requests respond with `200 OK`; we then drop the partial and
/// start over from scratch.
///
/// Lifecycle of a single file:
///   * `pending` → never been touched.
///   * `running` → bytes are streaming in.
///   * `completed` → server sent the full file, disk write
///     succeeded.
///   * `cancelled` → user tapped Cancel. Partial file is kept on
///     disk so they can resume.
///   * `failed` → network / HTTP / I/O error. Partial file is
///     kept on disk so they can resume.
class BuiltinModelDownloadService extends ChangeNotifier {
  BuiltinModelDownloadService({
    http.Client? httpClient,
    Future<Directory> Function()? docsDirResolver,
  }) : _client = httpClient ?? http.Client(),
       _docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory,
       _ownsClient = httpClient == null;

  final http.Client _client;
  final Future<Directory> Function() _docsDirResolver;
  final bool _ownsClient;

  /// Per-model download state. Survives across page pop / push so
  /// a backgrounded download can be re-displayed on the next visit.
  final Map<String, BuiltinModelDownloadState> _states = {};

  /// Per-model active subscription, so we can cancel an in-flight
  /// download. The subscription lives on the service (not on a
  /// page) so the download keeps running even if the page is
  /// disposed.
  final Map<String, _ActiveDownload> _active = {};

  /// Per-model cancel flag, flipped by [cancel] and read by the
  /// file stream's loop.
  final Map<String, _CancelFlag> _cancelFlags = {};

  /// Returns the current download state for a model, or `null` if
  /// no download has been started for it (or the state was
  /// cleared). The page uses this to render the download card
  /// (which may show live progress, a terminal status, or nothing
  /// if the user hasn't touched it yet).
  BuiltinModelDownloadState? stateFor(String builtinModelId) {
    return _states[builtinModelId];
  }

  /// True when a download is currently in progress for [model].
  /// Used by the page to show "取消下载" instead of "下载".
  bool isActive(String builtinModelId) => _active.containsKey(builtinModelId);

  /// Resolves the destination directory for [model] and creates
  /// it if needed. Lazy so the platform channel only fires when
  /// the user actually visits the download flow.
  Future<Directory> resolveModelDir(BuiltinModel model) async {
    final docs = await _docsDirResolver();
    final dir = Directory(p.join(docs.path, 'local_models', model.id));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Returns the destination directory + the absolute paths the
  /// model weights / mmproj will land in, even before the download
  /// starts. Used by the settings page to render the "Will be
  /// saved to ..." hint.
  Future<({Directory dir, String modelPath, String? mmprojPath})> resolvePaths(
    BuiltinModel model,
  ) async {
    final dir = await resolveModelDir(model);
    final modelPath = p.join(dir.path, model.modelFilename);
    final mmprojPath = model.hasMmproj
        ? p.join(dir.path, model.mmprojFilename!)
        : null;
    return (dir: dir, modelPath: modelPath, mmprojPath: mmprojPath);
  }

  /// True when both the model and (if applicable) the mmproj file
  /// are on disk and the file is non-empty. The settings page
  /// uses this to render the "已下载" badge.
  ///
  /// Note: this only checks file presence + size. It does NOT
  /// require a [BuiltinModelDownloadState] — the file may have
  /// landed via a previous app session that we don't remember.
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

  /// Reads the current on-disk size of the model file. Useful
  /// for the "downloaded X MB so far" hint on a partial download
  /// (e.g. the user re-opens the page after killing the app).
  Future<int> partialModelSize(BuiltinModel model) async {
    try {
      final paths = await resolvePaths(model);
      final f = File(paths.modelPath);
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  Future<int> partialMmprojSize(BuiltinModel model) async {
    if (!model.hasMmproj) return 0;
    try {
      final paths = await resolvePaths(model);
      final f = File(paths.mmprojPath!);
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// Start (or resume) a download for [model].
  ///
  /// If a download is already in progress for this model (the
  /// user navigated away and came back, or tapped the button
  /// twice in a row), this is a no-op — the existing download
  /// keeps running and the existing state stays.
  ///
  /// If a previous download is in a terminal state (cancelled /
  /// failed / completed) but hasn't been fully cleaned up yet
  /// — e.g. the onDone callback hasn't fired yet, but the
  /// state is already terminal — we drop the stale `_active`
  /// entry and start a fresh run. This is what makes "tap
  /// Resume" right after "tap Cancel" work without races.
  ///
  /// If a partial file is on disk from a previous run, the next
  /// HTTP request goes out with `Range: bytes=<size>-` and the
  /// server is expected to answer with `206 Partial Content`. If
  /// the server doesn't support range requests, we drop the
  /// partial and start over.
  ///
  /// The actual transfer runs in the background. The page
  /// receives state updates via [ChangeNotifier.notifyListeners];
  /// the underlying [notifyListeners] calls are throttled by the
  /// stream's yield cadence (every ~128 KB of bytes).
  void startDownload(BuiltinModel model) {
    final existing = _states[model.id];
    if (_active.containsKey(model.id) &&
        (existing == null || !existing.isTerminal)) {
      return;
    }
    // A previous run has fully wound down (or hasn't started).
    // Clean up any stale _active entry before we start a new
    // one.
    _active.remove(model.id);
    _cancelFlags.remove(model.id);
    _spawnDownload(model);
  }

  /// Cancel an in-flight download. The active subscription is
  /// closed and the per-file status is flipped to `cancelled`.
  /// **The partial file is kept on disk** so the user can resume
  /// from the breakpoint by calling [startDownload] again.
  ///
  /// Safe to call when no download is active (no-op).
  void cancel(String builtinModelId) {
    final flag = _cancelFlags.remove(builtinModelId);
    if (flag != null) flag.value = true;
  }

  /// Drop the in-memory state for [model]. Used after a
  /// successful save (the file is on disk + a LocalProvider
  /// points to it; the in-memory state would just be stale
  /// noise). The on-disk partial file is **not** touched.
  void clearState(String builtinModelId) {
    if (_states.remove(builtinModelId) != null) {
      notifyListeners();
    }
  }

  /// Drop the on-disk model + mmproj files for [model] (best
  /// effort). Used when the user picks "重新下载" — we want the
  /// next [startDownload] to start from a clean slate.
  Future<void> deleteDownloadedFiles(BuiltinModel model) async {
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
      // will overwrite the file (or fail explicitly if it's
      // locked) — we don't block the UI on this.
    }
  }

  /// Drop a single downloaded file (best effort) for [model],
  /// identified by the [BuiltinFileDownload] object the page is
  /// currently rendering. Used by the per-file "Delete" button
  /// on the download card. The on-disk file is removed and the
  /// in-memory state for that slot is reset to a fresh
  /// `pending` snapshot, with the overall phase recomputed.
  ///
  /// No-op if the model has no state, or if [file] doesn't
  /// match either of the two slots the service knows about.
  Future<void> deleteDownloadedFile(
    BuiltinModel model,
    BuiltinFileDownload file,
  ) async {
    final state = _states[model.id];
    final localPath = file.localPath;
    if (localPath != null) {
      try {
        final f = File(localPath);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      } catch (_) {
        // Best-effort. Don't block the UI on I/O errors.
      }
    }
    if (state == null) return;
    final isModel = file.url == model.modelUrl;
    final BuiltinModelDownloadState newState;
    if (isModel) {
      newState = BuiltinModelDownloadState(
        model: state.model,
        modelFile: BuiltinFileDownload(
          url: model.modelUrl,
          filename: model.modelFilename,
        ),
        mmprojFile: state.mmprojFile,
        overall: _recomputeOverallPhase(
          modelFile: BuiltinFileDownload(
            url: model.modelUrl,
            filename: model.modelFilename,
          ),
          mmprojFile: state.mmprojFile,
        ),
      );
    } else {
      newState = BuiltinModelDownloadState(
        model: state.model,
        modelFile: state.modelFile,
        mmprojFile: BuiltinFileDownload(
          url: model.mmprojUrl!,
          filename: model.mmprojFilename!,
        ),
        overall: _recomputeOverallPhase(
          modelFile: state.modelFile,
          mmprojFile: BuiltinFileDownload(
            url: model.mmprojUrl!,
            filename: model.mmprojFilename!,
          ),
        ),
      );
    }
    _states[model.id] = newState;
    notifyListeners();
  }

  /// Compute the top-level phase from the two per-file slots.
  /// Mirrors the rules baked into [_runDownload] so the page
  /// renders the same overall state after a per-file delete.
  static BuiltinModelDownloadPhase _recomputeOverallPhase({
    required BuiltinFileDownload modelFile,
    BuiltinFileDownload? mmprojFile,
  }) {
    if (modelFile.status == BuiltinFileStatus.running) {
      return BuiltinModelDownloadPhase.downloadingModel;
    }
    if (mmprojFile?.status == BuiltinFileStatus.running) {
      return BuiltinModelDownloadPhase.downloadingMmproj;
    }
    final modelDone = modelFile.status == BuiltinFileStatus.completed;
    final mmprojDone =
        mmprojFile == null || mmprojFile.status == BuiltinFileStatus.completed;
    if (modelDone && mmprojDone) {
      return BuiltinModelDownloadPhase.completed;
    }
    if (modelFile.status == BuiltinFileStatus.failed ||
        mmprojFile?.status == BuiltinFileStatus.failed) {
      return BuiltinModelDownloadPhase.failed;
    }
    if (modelFile.status == BuiltinFileStatus.cancelled ||
        mmprojFile?.status == BuiltinFileStatus.cancelled) {
      return BuiltinModelDownloadPhase.cancelled;
    }
    return BuiltinModelDownloadPhase.idle;
  }

  void _spawnDownload(BuiltinModel model) {
    final cancelFlag = _CancelFlag();
    _cancelFlags[model.id] = cancelFlag;

    // Seed the state with a "starting" snapshot so the UI can
    // render the two rows from the very first frame. localPath
    // is left as null — it'll be filled in by the first yield
    // from _runDownload after resolvePaths completes.
    final initial = BuiltinModelDownloadState(
      model: model,
      modelFile: BuiltinFileDownload(
        url: model.modelUrl,
        filename: model.modelFilename,
      ),
      mmprojFile: model.hasMmproj
          ? BuiltinFileDownload(
              url: model.mmprojUrl!,
              filename: model.mmprojFilename!,
            )
          : null,
      overall: BuiltinModelDownloadPhase.downloadingModel,
    );
    _states[model.id] = initial;
    notifyListeners();

    // Track that an active download is running so
    // [isActive] returns the right value.
    _active[model.id] = _ActiveDownload();

    // Resolve the destination paths up-front. The resolvePaths
    // call hits path_provider; do it before subscribing so the
    // UI knows where the file is going to land.
    _runDownload(
      model: model,
      cancelFlag: cancelFlag,
      pathResolver: () => resolvePaths(model),
    ).listen(
      (s) {
        _states[model.id] = s;
        notifyListeners();
      },
      onDone: () {
        _active.remove(model.id);
        _cancelFlags.remove(model.id);
        notifyListeners();
      },
      onError: (Object e, StackTrace st) {
        // _runDownload shouldn't throw (it surfaces errors via
        // the stream), but if it does, mark the model as failed.
        final cur = _states[model.id];
        if (cur != null) {
          _states[model.id] = cur.copyWith(
            overall: BuiltinModelDownloadPhase.failed,
          );
        }
        _active.remove(model.id);
        _cancelFlags.remove(model.id);
        notifyListeners();
      },
    );
  }

  /// Runs the full download for [model] (model weights, then
  /// mmproj if any). The output stream is what the page + the
  /// service's [notifyListeners] plumbing both consume.
  Stream<BuiltinModelDownloadState> _runDownload({
    required BuiltinModel model,
    required _CancelFlag cancelFlag,
    required Future<({Directory dir, String modelPath, String? mmprojPath})>
    Function()
    pathResolver,
  }) async* {
    final paths = await pathResolver();

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
        cancelled: () => cancelFlag.value,
      )) {
        if (progress.cancelled) {
          state = state.copyWith(
            modelFile: state.modelFile.copyWith(
              bytesReceived: progress.bytesReceived,
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
          // Preserve the bytes-received on the failed row so the
          // UI can show "downloaded X so far" + "retry from X".
          state = state.copyWith(
            modelFile: state.modelFile.copyWith(
              bytesReceived: progress.bytesReceived,
            ),
          );
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
          cancelled: () => cancelFlag.value,
        )) {
          if (progress.cancelled) {
            state = state.copyWith(
              mmprojFile: state.mmprojFile!.copyWith(
                bytesReceived: progress.bytesReceived,
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
            state = state.copyWith(
              mmprojFile: state.mmprojFile!.copyWith(
                bytesReceived: progress.bytesReceived,
              ),
            );
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
    } catch (e) {
      // _streamFile surfaces errors via the stream, so this catch
      // is only for unexpected programmer errors. Best-effort:
      // mark the download as failed and propagate.
      yield state.copyWith(
        overall: BuiltinModelDownloadPhase.failed,
        modelFile: state.modelFile.copyWith(
          status: BuiltinFileStatus.failed,
          error: e.toString(),
        ),
      );
    }
  }

  /// Streams `url` to `destPath`. Resumable: if a non-empty file
  /// already exists at `destPath`, sends a `Range: bytes=N-`
  /// request and appends the response body. If the server
  /// responds with `200` (doesn't honour the range), the partial
  /// is discarded and the file is re-downloaded from scratch.
  ///
  /// Yields [_FileProgress] events as bytes arrive. Exactly one
  /// terminal event — `success`, `cancelled`, or
  /// `errorMessage != null` — is emitted at the end.
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
    var resumeFrom = 0;
    if (await file.exists()) {
      resumeFrom = await file.length();
    }

    http.StreamedResponse response;
    var resumableAttempted = false;

    // Try to resume if we have a partial on disk.
    if (resumeFrom > 0) {
      resumableAttempted = true;
      final req = http.Request('GET', uri);
      req.headers['Range'] = 'bytes=$resumeFrom-';
      final r = await _client.send(req);
      if (r.statusCode == 206) {
        response = r;
      } else {
        // Server didn't honour the range. Drain + discard, then
        // re-request from scratch below.
        await r.stream.drain<void>().catchError((_) {});
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }
        resumeFrom = 0;
        final fallback = http.Request('GET', uri);
        final fr = await _client.send(fallback);
        if (fr.statusCode < 200 || fr.statusCode >= 300) {
          await fr.stream.drain<void>().catchError((_) {});
          yield _FileProgress.failure('HTTP ${fr.statusCode}');
          return;
        }
        response = fr;
      }
    } else {
      final req = http.Request('GET', uri);
      final r = await _client.send(req);
      if (r.statusCode < 200 || r.statusCode >= 300) {
        await r.stream.drain<void>().catchError((_) {});
        yield _FileProgress.failure('HTTP ${r.statusCode}');
        return;
      }
      response = r;
    }

    // We append when the server honoured our range, and we
    // overwrite otherwise (either the server returned 200 or
    // there was no partial to begin with).
    final isAppend = resumableAttempted && response.statusCode == 206;
    final sink = file.openWrite(
      mode: isAppend ? FileMode.append : FileMode.write,
    );
    var bytesReceived = resumeFrom;
    var bytesTotal = response.contentLength ?? -1;
    if (bytesTotal > 0 && isAppend) {
      // Content-Length of a partial response is the length of
      // the remainder; add the offset so the UI can show a
      // consistent total.
      bytesTotal = resumeFrom + bytesTotal;
    }
    yield _FileProgress(bytesReceived: bytesReceived, bytesTotal: bytesTotal);

    try {
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
        // enough that per-chunk updates would just stall the UI
        // on a 1.7 GB model.
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
        // Flush + close the sink, but keep the partial file on
        // disk so a future call to startDownload can resume from
        // the breakpoint. The `bytesReceived` is preserved on
        // the cancelled event so the outer state machine can
        // surface "downloaded X so far" + "Resume".
        try {
          await sink.flush();
        } catch (_) {}
        try {
          await sink.close();
        } catch (_) {}
        yield _FileProgress(
          bytesReceived: bytesReceived,
          bytesTotal: bytesTotal,
          cancelled: true,
        );
        return;
      }
      if (bytesReceived == resumeFrom) {
        // We didn't receive any new bytes. This is unexpected
        // (the server reported 200/206 but sent no body) — treat
        // as a hard failure.
        await _disposeSink(sink, file);
        if (resumeFrom > 0) {
          // Drop the partial so the next attempt starts clean.
          if (await file.exists()) {
            try {
              await file.delete();
            } catch (_) {}
          }
        }
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
      // The partial file is left on disk so the user can resume.
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

  @override
  void dispose() {
    // Cancel every active download. We intentionally keep the
    // partial files on disk — the next session can resume from
    // the breakpoint.
    for (final flag in _cancelFlags.values) {
      flag.value = true;
    }
    _cancelFlags.clear();
    _active.clear();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// Holds the in-flight subscription for an active download. We
/// don't currently need to do anything with the subscription
/// itself (the listen() returned by `_runDownload` holds the
/// reference), but the map itself is what makes
/// [BuiltinModelDownloadService.isActive] return the right value.
class _ActiveDownload {
  _ActiveDownload();
}

/// Mutable boolean holder. Used as the cancel flag for a
/// per-file stream so [BuiltinModelDownloadService.cancel] can
/// flip the value from the outside.
class _CancelFlag {
  bool value = false;
}

/// One event emitted by [_streamFile]. `bytesReceived` /
/// `bytesTotal` carry the running counters; exactly one of
/// `success` / `cancelled` / `errorMessage` is non-null on the
/// terminal event (and all are null on intermediate progress
/// updates). `bytesReceived` is preserved on `cancelled` events
/// so the outer state machine can decide whether there's a
/// partial file worth resuming from.
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

  final int bytesReceived;
  final int bytesTotal;
  final bool success;
  final bool cancelled;
  final String? errorMessage;
}
