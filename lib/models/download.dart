import 'dart:convert';

/// One download spawned by the `download` tool. Lives on
/// [ToolCall.downloads]; the chat provider mutates the list in
/// place as the download progresses so the message bubble can
/// repaint with a live progress bar.
class DownloadItem {
  final String id;

  /// Source URL the model asked to download.
  final String url;

  /// Filename the file is saved as in the temp directory. May
  /// differ from the filename the model asked for — we sanitize
  /// it (strip path separators, fall back to a generic name).
  final String filename;

  /// Bytes received so far. Increases monotonically while
  /// [status] == [DownloadStatus.running]. `0` when the server
  /// didn't send a `Content-Length` header.
  final int bytesReceived;

  /// Total bytes expected, from the `Content-Length` header. `-1`
  /// when the server didn't send it (chunked transfer, or
  /// `HEAD` failed and we skipped the size probe).
  final int bytesTotal;

  /// Current lifecycle stage. The model-visible envelope is
  /// always emitted on the [DownloadStatus.completed] /
  /// [DownloadStatus.failed] transitions.
  final DownloadStatus status;

  /// Optional error message on [DownloadStatus.failed].
  final String? error;

  /// Absolute path to the file in the app's temp directory.
  /// `null` while pending, while running, and after a
  /// successful save (the temp file is deleted at save time so
  /// we don't leak disk space). After an app restart, the path
  /// is still populated but the file may not exist on disk —
  /// the UI checks [File.exists] before offering the save
  /// button.
  final String? localPath;

  /// Final path after the user has saved the file to a folder
  /// of their choice. `null` until the user picks a directory
  /// and we copy the file over. Persisted across app restarts.
  final String? savedPath;

  /// Free-form note: `Content-Type` (when known), the source
  /// filename parsed from the `Content-Disposition` header, etc.
  /// Not used by the model — only for the UI.
  final String? contentType;

  const DownloadItem({
    required this.id,
    required this.url,
    required this.filename,
    this.bytesReceived = 0,
    this.bytesTotal = -1,
    this.status = DownloadStatus.pending,
    this.error,
    this.localPath,
    this.savedPath,
    this.contentType,
  });

  /// 0.0 → 1.0. Falls back to indeterminate when the server
  /// didn't send a Content-Length.
  double? get fraction {
    if (bytesTotal <= 0) return null;
    final f = bytesReceived / bytesTotal;
    if (f.isNaN || f.isInfinite) return null;
    return f.clamp(0.0, 1.0);
  }

  bool get isRunning => status == DownloadStatus.running;
  bool get isCompleted => status == DownloadStatus.completed;
  bool get isFailed => status == DownloadStatus.failed;
  bool get isCancelled => status == DownloadStatus.cancelled;
  bool get isDone =>
      status == DownloadStatus.completed ||
      status == DownloadStatus.failed ||
      status == DownloadStatus.cancelled ||
      status == DownloadStatus.saved;

  /// True once the user has confirmed a save target.
  bool get isSaved => status == DownloadStatus.saved;

  DownloadItem copyWith({
    int? bytesReceived,
    int? bytesTotal,
    DownloadStatus? status,
    String? error,
    String? localPath,
    String? savedPath,
    String? contentType,
  }) {
    return DownloadItem(
      id: id,
      url: url,
      filename: filename,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      status: status ?? this.status,
      error: error ?? this.error,
      localPath: localPath ?? this.localPath,
      savedPath: savedPath ?? this.savedPath,
      contentType: contentType ?? this.contentType,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'filename': filename,
    'bytesReceived': bytesReceived,
    'bytesTotal': bytesTotal,
    'status': status.name,
    'error': error,
    'localPath': localPath,
    'savedPath': savedPath,
    'contentType': contentType,
  };

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    return DownloadItem(
      id: json['id'] as String,
      url: json['url'] as String,
      filename: json['filename'] as String? ?? 'download',
      bytesReceived: (json['bytesReceived'] as num?)?.toInt() ?? 0,
      bytesTotal: (json['bytesTotal'] as num?)?.toInt() ?? -1,
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DownloadStatus.pending,
      ),
      error: json['error'] as String?,
      localPath: json['localPath'] as String?,
      savedPath: json['savedPath'] as String?,
      contentType: json['contentType'] as String?,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory DownloadItem.fromRawJson(String raw) =>
      DownloadItem.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

enum DownloadStatus {
  /// Queued — the tool call started but no bytes have arrived yet.
  pending,

  /// Actively streaming.
  running,

  /// Finished, file is sitting in the temp dir awaiting the
  /// user's "save" decision.
  completed,

  /// Network or I/O failure. [DownloadItem.error] has the reason.
  failed,

  /// User (or orchestrator) called cancel before completion.
  cancelled,

  /// User has saved the file to a folder of their choice. The
  /// temp file is gone at this point.
  saved,
}
