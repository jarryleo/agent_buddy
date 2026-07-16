import 'dart:convert';

/// One file the user picked from the system file picker. Returned
/// from [FileService.pick] and stored in the `FileBridge`'s
/// per-app in-memory map keyed by [id].
///
/// The model-side view is just `picker://<id>` + a few display
/// fields. The underlying native URI / URL is kept server-side
/// and never leaked to the model.
class PickedFile {
  const PickedFile({
    required this.id,
    required this.name,
    required this.size,
    this.mimeType,
    required this.path,
  });

  /// Stable handle minted by the bridge (e.g. `f_42`). The
  /// model addresses the file as `picker://<id>`.
  final String id;

  /// Best-effort display name from the picker (`Documents/foo.txt`).
  final String name;

  /// Size in bytes. `-1` when the picker could not determine it
  /// (e.g. the source provider is a `DocumentProvider` that
  /// doesn't expose a `size` column).
  final int size;

  /// MIME type as advertised by the picker. `null` when unknown.
  final String? mimeType;

  /// `picker://<id>` — what the model passes back as the `path`
  /// to `read` / `write` / `append` / `read_attr`.
  final String path;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    if (mimeType != null) 'mime_type': mimeType,
    'path': path,
  };

  factory PickedFile.fromJson(Map<String, dynamic> json) => PickedFile(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? -1,
    mimeType: json['mime_type'] as String?,
    path: json['path'] as String,
  );

  String toRawJson() => jsonEncode(toJson());
  factory PickedFile.fromRawJson(String raw) =>
      PickedFile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// One entry returned by [FileService.listDir]. Mirrors the
/// desktop `file` tool's `list_dir` envelope entries so the
/// model sees the same shape on every platform.
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modifiedMs,
  });

  final String name;

  /// `working://...` form (the model never sees the underlying
  /// absolute path).
  final String path;
  final bool isDirectory;
  final int size;
  final int modifiedMs;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'type': isDirectory ? 'dir' : 'file',
    'size': size,
    'modified_ms': modifiedMs,
  };

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
    name: json['name'] as String,
    path: json['path'] as String,
    isDirectory: json['is_directory'] as bool? ?? false,
    size: (json['size'] as num?)?.toInt() ?? 0,
    modifiedMs:
        (json['modified_ms'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch,
  );
}

/// Result of [FileService.readAttr]. Mirrors the desktop
/// `read_attr` envelope so the model gets the same shape.
class FileAttrs {
  const FileAttrs({
    required this.path,
    required this.type,
    required this.size,
    required this.modifiedMs,
    required this.accessedMs,
    required this.changedMs,
    required this.isDirectory,
    required this.isFile,
    required this.isLink,
  });

  final String path;
  final String type;
  final int size;
  final int modifiedMs;
  final int accessedMs;
  final int changedMs;
  final bool isDirectory;
  final bool isFile;
  final bool isLink;

  Map<String, dynamic> toJson() => {
    'path': path,
    'type': type,
    'size': size,
    'modified_ms': modifiedMs,
    'accessed_ms': accessedMs,
    'changed_ms': changedMs,
    'is_directory': isDirectory,
    'is_file': isFile,
    'is_link': isLink,
  };

  factory FileAttrs.fromJson(Map<String, dynamic> json) => FileAttrs(
    path: json['path'] as String,
    type: json['type'] as String? ?? 'other',
    size: (json['size'] as num?)?.toInt() ?? 0,
    modifiedMs:
        (json['modified_ms'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch,
    accessedMs:
        (json['accessed_ms'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch,
    changedMs:
        (json['changed_ms'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch,
    isDirectory: json['is_directory'] as bool? ?? false,
    isFile: json['is_file'] as bool? ?? false,
    isLink: json['is_link'] as bool? ?? false,
  );
}
