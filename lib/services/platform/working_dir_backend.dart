import 'package:flutter/services.dart';

import '../../models/picked_file.dart';

/// Marker thrown when the user dismisses a re-authorization
/// prompt the native bridge surfaced mid-operation (e.g. their
/// SAF tree URI was revoked and the bridge asked them to
/// re-pick a folder). The `FileService` translates this to a
/// `FileServiceError` with a clear hint to the model.
class WorkingDirCancelledException implements Exception {
  const WorkingDirCancelledException();
  @override
  String toString() =>
      'working directory access was denied by the user; '
      'ask the user to re-pick a folder via the chat toolbar';
}

/// Abstract surface for the SAF-backed working-directory
/// backend. Production implementation is
/// [MethodChannelWorkingDirBackend] (Android only); tests can
/// inject a fake via [FileServiceImpl].
///
/// The backend handles the entire re-authorization flow
/// internally: an `auth_revoked` error raised by an op
/// triggers a fresh `ACTION_OPEN_DOCUMENT_TREE` prompt, the
/// new tree URI is persisted to the bridge's own
/// SharedPreferences, the original op is retried, and only the
/// terminal result is surfaced to the caller. So the Dart-side
/// `FileService` only needs to map `cancelled` /
/// success / error into its own error envelope.
abstract class WorkingDirBackend {
  /// Open the system folder picker to (re-)select the
  /// working-directory tree. **Blocks until the user picks,
  /// cancels, or the OS dismisses the picker.** Returns the
  /// newly-picked `(displayPath, treeUri)` pair, or `null`
  /// when the user explicitly cancelled.
  Future<({String path, String treeUri})?> pickWorkingDirectory();

  /// Write (or append) raw bytes to `<relPath>` inside the
  /// persisted working-directory tree. Auto-creates missing
  /// parent directories. Throws [WorkingDirCancelledException]
  /// when the re-auth prompt is dismissed; otherwise returns
  /// normally or throws an [Exception] for non-auth errors.
  Future<void> writeRel(String relPath, Uint8List bytes, {bool append = false});

  /// Read raw bytes from `<relPath>` inside the working
  /// directory, capped at [maxBytes]. Throws
  /// [WorkingDirCancelledException] on a dismissed re-auth.
  Future<Uint8List> readRel(String relPath, {required int maxBytes});

  /// Recursively create any missing directories in [relPath].
  /// No-op if the path already exists. Throws
  /// [WorkingDirCancelledException] on a dismissed re-auth.
  Future<void> mkdirsRel(String relPath);

  /// List the immediate children of `<relPath>`. Returns
  /// `FileEntry` records whose `path` is a model-friendly
  /// `working://<rel>` form. Caps at 200 entries to match the
  /// desktop `file` tool's behaviour.
  Future<List<FileEntry>> listRel(String relPath, {bool recursive = false});

  /// Delete a file or directory. Throws
  /// [WorkingDirCancelledException] on a dismissed re-auth.
  Future<void> deleteRel(String relPath, {bool recursive = false});

  /// Rename / move inside the working directory. The
  /// destination must not already exist. Throws
  /// [WorkingDirCancelledException] on a dismissed re-auth.
  Future<void> renameRel(String from, String to);

  /// Read attributes (size, mtime, etc) for a file or
  /// directory. Throws [WorkingDirCancelledException] on a
  /// dismissed re-auth.
  Future<FileAttrs> readAttrRel(String relPath);
}

/// Production backend: routes every working-dir op to the
/// `agent_buddy/file` MethodChannel. The native side is the
/// authority on the tree URI and the re-auth flow, so the
/// Dart-side surface is intentionally thin.
///
/// Wire envelope contract (write / delete / rename / mkdirs):
///   * `null`                       - success
///   * `{cancelled: true}`          - user dismissed re-auth
///   * `{ok: false, code, message}` - normal error
class MethodChannelWorkingDirBackend implements WorkingDirBackend {
  MethodChannelWorkingDirBackend([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('agent_buddy/file');

  final MethodChannel _channel;

  @override
  Future<({String path, String treeUri})?> pickWorkingDirectory() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'pickTree',
        const <String, dynamic>{},
      );
      if (raw == null) return null;
      if (raw['cancelled'] == true) return null;
      final path = raw['path'] as String?;
      final treeUri = raw['tree_uri'] as String?;
      if (path == null || path.isEmpty || treeUri == null || treeUri.isEmpty) {
        throw Exception(
          'pickTree returned a payload without path / tree_uri: $raw',
        );
      }
      return (path: path, treeUri: treeUri);
    } on PlatformException catch (e) {
      if (e.code == 'PICKER_CANCELLED') return null;
      throw Exception('pickTree failed: ${e.code}: ${e.message}');
    } on MissingPluginException {
      throw const NotImplementedWorkingDirOp();
    }
  }

  @override
  Future<void> writeRel(
    String relPath,
    Uint8List bytes, {
    bool append = false,
  }) => _invokeVoid('writeWorking', {
    'rel_path': relPath,
    'bytes': bytes,
    'append': append,
  });

  @override
  Future<Uint8List> readRel(String relPath, {required int maxBytes}) async {
    final raw = await _invokeDynamic('readWorking', {
      'rel_path': relPath,
      'max_bytes': maxBytes,
    });
    if (raw == null) return Uint8List(0);
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    if (raw is Map) _throwIfEnvelopeError(raw);
    return Uint8List(0);
  }

  @override
  Future<void> mkdirsRel(String relPath) =>
      _invokeVoid('mkdirsWorking', {'rel_path': relPath});

  @override
  Future<List<FileEntry>> listRel(
    String relPath, {
    bool recursive = false,
  }) async {
    Map<String, dynamic>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, dynamic>('listWorking', {
        'rel_path': relPath,
        'recursive': recursive,
      });
    } on PlatformException catch (e) {
      _translatePlatformException(e);
    }
    if (raw == null) {
      throw Exception('listWorking returned null');
    }
    _throwIfEnvelopeError(raw);
    final entries = (raw['entries'] as List? ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList(growable: false);
    return entries.map(_decodeEntry).toList(growable: false);
  }

  @override
  Future<void> deleteRel(String relPath, {bool recursive = false}) =>
      _invokeVoid('deleteWorking', {
        'rel_path': relPath,
        'recursive': recursive,
      });

  @override
  Future<void> renameRel(String from, String to) =>
      _invokeVoid('renameWorking', {'from': from, 'to': to});

  @override
  Future<FileAttrs> readAttrRel(String relPath) async {
    Map<String, dynamic>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, dynamic>('readAttrWorking', {
        'rel_path': relPath,
      });
    } on PlatformException catch (e) {
      _translatePlatformException(e);
    }
    if (raw == null) {
      throw Exception('readAttrWorking returned null');
    }
    _throwIfEnvelopeError(raw);
    return FileAttrs(
      path: 'working://$relPath',
      type: raw['type'] as String? ?? 'file',
      size: (raw['size'] as num?)?.toInt() ?? -1,
      modifiedMs:
          (raw['modified_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      accessedMs:
          (raw['accessed_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      changedMs:
          (raw['changed_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      isDirectory: raw['is_directory'] as bool? ?? false,
      isFile: raw['is_file'] as bool? ?? true,
      isLink: raw['is_link'] as bool? ?? false,
    );
  }

  Future<dynamic> _invokeDynamic(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      return await _channel.invokeMethod(method, args);
    } on PlatformException catch (e) {
      _translatePlatformException(e);
    }
  }

  Future<void> _invokeVoid(String method, Map<String, dynamic> args) async {
    final raw = await _invokeDynamic(method, args);
    if (raw is Map) _throwIfEnvelopeError(raw);
  }

  /// Translates a `PlatformException` raised by the native
  /// side (the bridge uses `result.error(code, message)` for
  /// normal errors) into the matching Dart exception, so the
  /// `FileService` sees a consistent error surface.
  Never _translatePlatformException(PlatformException e) {
    if (e.code == 'PATH_NOT_FOUND' ||
        e.code == 'FILE_TOO_LARGE' ||
        e.code == 'DIRECTORY_NOT_EMPTY' ||
        e.code == 'DESTINATION_EXISTS' ||
        e.code == 'INVALID_ARGUMENT') {
      throw Exception('${e.code}: ${e.message ?? e.code}');
    }
    throw Exception('${e.code}: ${e.message ?? 'unknown error'}');
  }

  /// Translates the bridge's standard envelope into the
  /// matching exception. A `null` / missing `cancelled` /
  /// `ok` field is treated as success.
  void _throwIfEnvelopeError(Map raw) {
    if (raw['cancelled'] == true) {
      throw const WorkingDirCancelledException();
    }
    if (raw['ok'] == false) {
      final code = raw['code'] as String? ?? 'BRIDGE_ERROR';
      final msg = raw['message'] as String? ?? code;
      throw Exception('$code: $msg');
    }
  }

  /// Re-shape a raw `{name, path, is_directory, size, modified_ms}`
  /// entry from the bridge into a [FileEntry]. The bridge always
  /// returns the path in `working://<rel>` form so the model
  /// can re-use it on follow-up turns.
  static FileEntry _decodeEntry(Map<String, dynamic> raw) {
    return FileEntry(
      name: raw['name'] as String? ?? '',
      path: raw['path'] as String? ?? '',
      isDirectory: raw['is_directory'] as bool? ?? false,
      size: (raw['size'] as num?)?.toInt() ?? 0,
      modifiedMs:
          (raw['modified_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class NotImplementedWorkingDirOp implements Exception {
  const NotImplementedWorkingDirOp();
  @override
  String toString() =>
      'working directory backend is not available '
      'on this platform (expected Android)';
}
