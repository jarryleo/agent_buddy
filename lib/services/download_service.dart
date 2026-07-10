import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/download.dart';
import 'tool_service.dart' show ToolException;

/// Signature for download progress callbacks. The chat provider
/// wires this to "update the in-place `DownloadItem` on the active
/// tool call and notify listeners" so the bubble's progress bar
/// repaints as bytes arrive.
typedef DownloadProgressCallback = void Function(DownloadItem item);

/// Owns file downloads for the `download` tool. The lifecycle is:
///
///   1. `download()` starts streaming the URL into a file in
///      [getTemporaryDirectory] under `downloads/<uuid>__<filename>`.
///      The model-visible card (a `DownloadItem` in
///      `ToolCall.downloads`) flips through `pending → running →
///      completed`. Progress callbacks fire as bytes arrive so
///      the UI can repaint the progress bar.
///   2. The user reads the file's name in the chat, then taps
///      "Save". The chat provider hands a destination directory
///      (chosen via the system folder picker) to [saveTo] which
///      copies the temp file to `<destDir>/<safeFilename>` and
///      returns the final path. The temp file is then removed.
///   3. If the user doesn't save, the file sits in the temp dir
///      until the next OS-driven temp cleanup pass wipes it
///      (we don't proactively clean up — the OS will get to it).
///
/// Cancellation is supported: [cancel] aborts the in-flight HTTP
/// request and marks the item `cancelled`. The partial file is
/// removed.
class DownloadService {
  DownloadService({http.Client? httpClient, Directory? tempDir, Uuid? uuid})
    : _ownsClient = httpClient == null,
      _client = httpClient ?? http.Client(),
      _uuid = uuid ?? const Uuid(),
      _tempDir = tempDir;

  late final http.Client _client;
  late final bool _ownsClient;
  final Uuid _uuid;

  // Resolved on first download. If the caller injected a
  // [tempDir] (tests), we use it; otherwise we fall through to
  // [getTemporaryDirectory] which throws on web.
  Directory? _tempDir;
  Directory? _downloadsSubdir;

  /// Currently active downloads keyed by [DownloadItem.id]. Used
  /// by [cancel] to look up the right HTTP request to abort. We
  /// use a simple [StreamSubscription] wrapper so cancellation
  /// works without pulling in a third-party cancelable package.
  final Map<String, _ActiveDownload> _active = {};

  /// Resolves the temp dir + creates the `downloads/` subdir
  /// lazily. We do this on first download rather than in the
  /// constructor because path_provider's web stub throws and
  /// we want the service to construct cleanly on platforms
  /// that don't support downloads.
  Future<Directory> _ensureDownloadsDir() async {
    final cached = _downloadsSubdir;
    if (cached != null) return cached;
    final base = await _resolveTempDir();
    final sub = Directory(p.join(base.path, 'downloads'));
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    _downloadsSubdir = sub;
    return sub;
  }

  Future<Directory> _resolveTempDir() async {
    final cached = _tempDir;
    if (cached != null) return cached;
    final dir = await getTemporaryDirectory();
    _tempDir = dir;
    return dir;
  }

  /// Convenience: total disk usage of the `downloads/` subdir.
  /// Mostly exposed for tests + future "clear all" affordance.
  Future<int> totalBytesOnDisk() async {
    final dir = _downloadsSubdir;
    if (dir == null || !await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// Starts a download. Returns a [Stream] of [DownloadItem]
  /// snapshots — one initial `pending` snapshot, a series of
  /// `running` snapshots as bytes arrive, then a final `completed`
  /// snapshot. The stream emits a single terminal event for both
  /// the success and failure cases (`failed` for HTTP / I/O
  /// errors, `cancelled` if the caller calls [cancel] with the
  /// item's id).
  ///
  /// Callers that don't care about progress can just await the
  /// stream's terminal event and inspect the final item.
  Stream<DownloadItem> download({
    required String url,
    String? filename,
    required String downloadId,
  }) async* {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw ToolException('invalid URL: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ToolException('only http(s) URLs are supported: $url');
    }

    final downloadsDir = await _ensureDownloadsDir();
    final resolvedFilename = _resolveFilename(uri, filename);
    // Namespace the temp file by the download id so two parallel
    // downloads of the same URL don't clobber each other.
    final localPath = p.join(
      downloadsDir.path,
      '${downloadId}__$resolvedFilename',
    );

    final file = File(localPath);
    final sink = file.openWrite();
    var cancelled = false;
    final active = _ActiveDownload(
      cancel: () {
        cancelled = true;
      },
    );
    _active[downloadId] = active;

    var bytesReceived = 0;
    var bytesTotal = -1;
    String? contentType;
    String? contentDisposition;
    String? errorMessage;

    DownloadItem snapshot({
      required DownloadStatus status,
      String? error,
      String? localPathSnap,
    }) {
      return DownloadItem(
        id: downloadId,
        url: url,
        filename: resolvedFilename,
        bytesReceived: bytesReceived,
        bytesTotal: bytesTotal,
        status: status,
        error: error,
        localPath: localPathSnap,
        contentType: contentType,
      );
    }

    try {
      // Yield the initial "pending" state so the UI can render
      // a placeholder row before any bytes arrive.
      yield snapshot(status: DownloadStatus.pending);

      final req = http.Request('GET', uri);
      req.headers['User-Agent'] =
          'Mozilla/5.0 (compatible; AgentBuddy/1.0; +https://agent.buddy)';
      final response = await _client.send(req);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        errorMessage = 'HTTP ${response.statusCode}';
        await response.stream.drain<void>().catchError((_) {});
        // We opened the temp file before sending the request
        // (so the path is reserved / visible) but we never
        // wrote a byte to it. Drop it now so a failed
        // download doesn't leave a zero-byte artefact in the
        // temp dir.
        try {
          await sink.close();
        } catch (_) {}
        if (await file.exists()) {
          try {
            await file.delete();
          } catch (_) {}
        }
        yield snapshot(status: DownloadStatus.failed, error: errorMessage);
        return;
      }
      contentType = response.headers['content-type'];
      contentDisposition = response.headers['content-disposition'];
      final cl = response.contentLength;
      if (cl != null && cl >= 0) bytesTotal = cl;
      // If the caller passed a filename, trust them — otherwise
      // try to pick one up from Content-Disposition. We don't
      // bother re-yielding just for a refined filename.

      yield snapshot(status: DownloadStatus.running);

      // 32 KB buffer. Big enough to amortize write syscalls,
      // small enough that progress is smooth.
      const chunkSize = 32 * 1024;
      final stream = response.stream;
      var receivedAny = false;

      await for (final chunk in stream.handleError((Object e, StackTrace s) {
        if (cancelled) return;
        throw e;
      })) {
        if (cancelled) break;
        if (chunk.isEmpty) continue;
        sink.add(chunk);
        bytesReceived += chunk.length;
        receivedAny = true;
        // Throttle: only yield on a 32 KB boundary or on the
        // last chunk. Yielding per chunk would flood the
        // notifyListeners path and stall the chat list.
        if (bytesReceived % (chunkSize * 4) < chunkSize) {
          yield snapshot(status: DownloadStatus.running);
        }
        // Race: if cancellation has been requested, stop
        // accumulating bytes and break the loop.
        if (cancelled) break;
      }

      // If the server used chunked transfer and we never saw
      // a Content-Length, fill in `bytesTotal` from the
      // accumulated byte count so the progress bar can land on
      // 100% at the end.
      if (bytesTotal < 0) bytesTotal = bytesReceived;

      if (cancelled) {
        errorMessage = 'cancelled';
        // Best-effort cleanup of partial bytes.
        await sink.close();
        if (await file.exists()) {
          await file.delete();
        }
        yield snapshot(status: DownloadStatus.cancelled, error: errorMessage);
        return;
      }

      // If we never received any bytes at all, the stream was
      // empty (the server returned 0 bytes without a 4xx). That's
      // an error from the model's perspective.
      if (!receivedAny) {
        await sink.close();
        if (await file.exists()) {
          await file.delete();
        }
        errorMessage = 'empty response';
        yield snapshot(status: DownloadStatus.failed, error: errorMessage);
        return;
      }

      // Honor `filename=` from Content-Disposition if the caller
      // didn't pin one — but only at the success path, so the
      // running progress is consistent.
      final cdFilename = _parseContentDispositionFilename(contentDisposition);
      final finalFilename = (filename == null && cdFilename != null)
          ? cdFilename
          : resolvedFilename;
      final finalItem = DownloadItem(
        id: downloadId,
        url: url,
        filename: finalFilename,
        bytesReceived: bytesReceived,
        bytesTotal: bytesTotal,
        status: DownloadStatus.completed,
        localPath: localPath,
        contentType: contentType,
      );
      await sink.flush();
      await sink.close();
      yield finalItem;
    } catch (e) {
      if (cancelled) {
        yield snapshot(status: DownloadStatus.cancelled, error: 'cancelled');
        return;
      }
      errorMessage = e.toString();
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      yield snapshot(status: DownloadStatus.failed, error: errorMessage);
    } finally {
      _active.remove(downloadId);
    }
  }

  /// Cancels an in-flight download by id. Safe to call multiple
  /// times and safe to call after the download has already
  /// finished (no-op in that case).
  void cancel(String downloadId) {
    final active = _active[downloadId];
    if (active != null) active.cancel();
  }

  /// Copies the file behind [item] to [destDir] and returns the
  /// final absolute path. Throws [ToolException] if the temp file
  /// is gone (e.g. the app was restarted between download and
  /// save). Cleans up the temp file on success.
  Future<String> saveTo({
    required DownloadItem item,
    required String destDir,
  }) async {
    if (item.localPath == null) {
      throw ToolException('download has no local file');
    }
    final src = File(item.localPath!);
    if (!await src.exists()) {
      throw ToolException(
        'temp file no longer exists (was the app restarted?); please re-download',
      );
    }
    if (!await Directory(destDir).exists()) {
      throw ToolException('destination directory does not exist: $destDir');
    }
    final finalPath = await _pickNonClashingPath(destDir, item.filename);
    try {
      await src.copy(finalPath);
    } on FileSystemException catch (e) {
      throw ToolException('failed to save file: ${e.message}');
    }
    // Best-effort: drop the temp file so the OS doesn't have to
    // wait for its own temp cleanup pass. We don't fail the save
    // if this throws — the user already has a copy in the
    // destination dir.
    try {
      await src.delete();
    } catch (_) {}
    return finalPath;
  }

  /// Removes the temp file behind [item], if any. Idempotent:
  /// silent no-op when the file is already gone.
  Future<void> cleanup(DownloadItem item) async {
    final p = item.localPath;
    if (p == null) return;
    final f = File(p);
    if (await f.exists()) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// Picks a non-clashing destination path. If `<destDir>/<name>`
  /// exists, append ` (1)`, ` (2)`, ... before the extension.
  Future<String> _pickNonClashingPath(String destDir, String filename) async {
    final dir = Directory(destDir);
    final ext = p.extension(filename);
    final stem = p.basenameWithoutExtension(filename);
    var candidate = p.join(dir.path, filename);
    var counter = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dir.path, '$stem ($counter)$ext');
      counter++;
      // 1000 is a hard cap to avoid an infinite loop if the
      // filesystem is misbehaving.
      if (counter > 1000) {
        throw ToolException(
          'too many existing files with the same name in $destDir',
        );
      }
    }
    return candidate;
  }

  /// Generates a unique download id. Wraps [Uuid.v4] so tests
  /// can inject a deterministic id generator.
  String newDownloadId() => _uuid.v4();

  /// Builds a default filename from the URL: prefer the last
  /// path segment, fall back to a generic name. Strips query
  /// strings and slashes.
  static String _resolveFilename(Uri uri, String? hint) {
    if (hint != null && hint.trim().isNotEmpty) {
      return _sanitize(hint.trim());
    }
    final segments = uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (segments.isNotEmpty) {
      final last = segments.last;
      // If the last segment looks like a file (has an
      // extension), keep it; otherwise fall back.
      if (last.contains('.')) return _sanitize(last);
    }
    return 'download_${DateTime.now().millisecondsSinceEpoch}';
  }

  static String _sanitize(String input) {
    // Drop path separators, control chars, and leading dots.
    final cleaned = input
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'^\.+'), '');
    if (cleaned.isEmpty) return 'download';
    // Cap at 200 chars to keep paths sane on every platform.
    if (cleaned.length > 200) return cleaned.substring(0, 200);
    return cleaned;
  }

  /// Best-effort parse of a `filename=` parameter from a
  /// Content-Disposition header. RFC 5987 `filename*=` is
  /// ignored for now (we don't fetch UTF-8 URLs that often).
  static String? _parseContentDispositionFilename(String? header) {
    if (header == null) return null;
    final match = RegExp(
      r'''filename\s*=\s*("([^"]+)"|([^;]+))''',
      caseSensitive: false,
    ).firstMatch(header);
    if (match == null) return null;
    final value = match.group(2) ?? match.group(3);
    if (value == null) return null;
    return _sanitize(value.trim());
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class _ActiveDownload {
  _ActiveDownload({required this.cancel});
  final void Function() cancel;
}
