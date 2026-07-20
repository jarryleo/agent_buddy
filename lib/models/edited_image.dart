import 'dart:convert';

/// One processed image emitted by the `edit_image` tool. Lives on
/// [ToolCall.editedImages] so the message bubble can render a
/// preview + Save affordance for each step without the tool
/// having to ship the bytes inside its `result` string.
///
/// The `path` points at a temp-directory file managed by
/// [ImageEditService] — the model never sees this path; only the
/// UI uses it to render the preview and to offer "Save" to a
/// folder the user picks.
class EditedImage {
  /// Absolute local path to the processed file in the app's
  /// temp directory. The path may become invalid across an app
  /// restart (OS wipes the temp dir) — the bubble checks
  /// `File.exists` before offering the Save affordance, just
  /// like `DownloadCard`.
  final String path;

  /// Filename as written to disk (used for "Save…" dialogs).
  final String filename;

  /// Pixel dimensions after the edit. Always set — even a
  /// pure compression pass preserves the dimensions.
  final int width;
  final int height;

  /// Bytes on disk. Lets the bubble show "832 KB → 412 KB" so
  /// the user can see the effect of a compress pass.
  final int size;

  /// Lower-case extension (without dot): `jpeg`, `png`, `webp`,
  /// `gif`, `bmp`. Mirrors the source format by default.
  final String format;

  /// The action that produced this image (`compress`, `crop`,
  /// `resize`, `rotate`). Surfaced in the bubble header so the
  /// user knows what each preview corresponds to.
  final String action;

  /// Original image dimensions, for comparison. `null` when the
  /// caller didn't supply them.
  final int? sourceWidth;
  final int? sourceHeight;
  final int? sourceSize;

  const EditedImage({
    required this.path,
    required this.filename,
    required this.width,
    required this.height,
    required this.size,
    required this.format,
    required this.action,
    this.sourceWidth,
    this.sourceHeight,
    this.sourceSize,
  });

  EditedImage copyWith({
    String? path,
    String? filename,
    int? width,
    int? height,
    int? size,
    String? format,
    String? action,
    int? sourceWidth,
    int? sourceHeight,
    int? sourceSize,
  }) {
    return EditedImage(
      path: path ?? this.path,
      filename: filename ?? this.filename,
      width: width ?? this.width,
      height: height ?? this.height,
      size: size ?? this.size,
      format: format ?? this.format,
      action: action ?? this.action,
      sourceWidth: sourceWidth ?? this.sourceWidth,
      sourceHeight: sourceHeight ?? this.sourceHeight,
      sourceSize: sourceSize ?? this.sourceSize,
    );
  }

  /// True if the source size is known and is larger than the
  /// edited size — used by the bubble to show a "−52%" badge.
  bool get shrankBytes {
    final s = sourceSize;
    return s != null && s > 0 && size < s;
  }

  /// Compression ratio as a signed percent change (negative =
  /// the file got smaller). `null` when we don't have a
  /// `sourceSize` to compare against.
  double? get sizeDeltaPercent {
    final s = sourceSize;
    if (s == null || s <= 0) return null;
    return (size - s) * 100.0 / s;
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'filename': filename,
    'width': width,
    'height': height,
    'size': size,
    'format': format,
    'action': action,
    if (sourceWidth != null) 'sourceWidth': sourceWidth,
    if (sourceHeight != null) 'sourceHeight': sourceHeight,
    if (sourceSize != null) 'sourceSize': sourceSize,
  };

  factory EditedImage.fromJson(Map<String, dynamic> json) {
    return EditedImage(
      path: json['path'] as String,
      filename: json['filename'] as String? ?? 'image',
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      size: (json['size'] as num?)?.toInt() ?? 0,
      format: json['format'] as String? ?? 'jpeg',
      action: json['action'] as String? ?? '',
      sourceWidth: (json['sourceWidth'] as num?)?.toInt(),
      sourceHeight: (json['sourceHeight'] as num?)?.toInt(),
      sourceSize: (json['sourceSize'] as num?)?.toInt(),
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory EditedImage.fromRawJson(String raw) =>
      EditedImage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
