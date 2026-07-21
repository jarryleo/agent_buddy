import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../models/picked_file.dart';
import 'file_service.dart';
import 'working_dir_backend.dart';

/// Backend that talks to the native bridge for picker-backed ops
/// (`pick` / `release` / read-write on `picker://<id>` paths).
///
/// Kept as a separate class so it can be swapped in tests with a
/// pure-Dart fake.
abstract class PickerFileBackend {
  Future<Map<String, dynamic>?> pick({String? mimeType, bool readOnly = false});

  Future<void> release(String id);

  Future<List<int>> read(String id, {required int maxBytes});

  Future<void> write(String id, List<int> bytes, {bool append = false});

  Future<Map<String, dynamic>> readAttr(String id);
}

/// Production backend: routes every picker op to the
/// `agent_buddy/file` MethodChannel.
class MethodChannelPickerBackend implements PickerFileBackend {
  MethodChannelPickerBackend([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('agent_buddy/file');

  final MethodChannel _channel;

  @override
  Future<Map<String, dynamic>?> pick({
    String? mimeType,
    bool readOnly = false,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('pick', {
        'mime_type': mimeType,
        'read_only': readOnly,
      });
      return raw;
    } on PlatformException catch (e) {
      throw _translatePlatformException(e, 'pick');
    } on MissingPluginException {
      throw const FileServiceNotSupportedError();
    }
  }

  @override
  Future<void> release(String id) async {
    try {
      await _channel.invokeMethod<void>('release', {'id': id});
    } on PlatformException catch (e) {
      throw _translatePlatformException(e, 'release');
    } on MissingPluginException {
      throw const FileServiceNotSupportedError();
    }
  }

  @override
  Future<List<int>> read(String id, {required int maxBytes}) async {
    try {
      final raw = await _channel.invokeMethod<Uint8List>('readPicker', {
        'id': id,
        'max_bytes': maxBytes,
      });
      return raw ?? const [];
    } on PlatformException catch (e) {
      throw _translatePlatformException(e, 'read');
    } on MissingPluginException {
      throw const FileServiceNotSupportedError();
    }
  }

  @override
  Future<void> write(String id, List<int> bytes, {bool append = false}) async {
    try {
      await _channel.invokeMethod<void>('writePicker', {
        'id': id,
        'bytes': Uint8List.fromList(bytes),
        'append': append,
      });
    } on PlatformException catch (e) {
      throw _translatePlatformException(e, 'write');
    } on MissingPluginException {
      throw const FileServiceNotSupportedError();
    }
  }

  @override
  Future<Map<String, dynamic>> readAttr(String id) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'readAttrPicker',
        {'id': id},
      );
      if (raw == null) {
        throw const FileServiceError('picker file not found');
      }
      return raw;
    } on PlatformException catch (e) {
      throw _translatePlatformException(e, 'readAttr');
    } on MissingPluginException {
      throw const FileServiceNotSupportedError();
    }
  }

  static FileServiceError _translatePlatformException(
    PlatformException e,
    String op,
  ) {
    switch (e.code) {
      case 'PICKER_CANCELLED':
        return FileServiceError(e.message ?? 'user cancelled the picker');
      case 'PICKER_DENIED':
        return FileServiceError(
          e.message ??
              'file access was denied; please grant access in system settings',
        );
      case 'FILE_TOO_LARGE':
        return FileServiceError(e.message ?? 'file too large');
      case 'PATH_NOT_FOUND':
        return FileServiceError(e.message ?? 'path not found');
      case 'NOT_SUPPORTED':
        return const FileServiceNotSupportedError();
      default:
        return FileServiceError('file $op failed: ${e.code}: ${e.message}');
    }
  }
}

/// Production [FileService]: picker paths via [PickerFileBackend];
/// working-directory paths (bare relative / `working://`) via
/// `dart:io` against the lazy [workingDirectoryLookup], or via
/// the SAF-backed [WorkingDirBackend] on Android (which is the
/// only platform where the model can realistically try to
/// write into a public volume like `/storage/emulated/0/...`).
///
/// The model defaults to the user-selected working directory or
/// to files the user explicitly picked - there are no other
/// sandbox roots.
class FileServiceImpl implements FileService {
  FileServiceImpl({
    PickerFileBackend? backend,
    String? Function()? workingDirectoryLookup,
    WorkingDirBackend? workingDirBackend,
    bool isAndroid = false,
  }) : _backend = backend ?? MethodChannelPickerBackend(),
       _workingDirectoryLookup = workingDirectoryLookup,
       _workingDirBackend = workingDirBackend,
       _isAndroid = isAndroid;

  final PickerFileBackend _backend;

  /// Lazy lookup for the current user-selected working directory.
  /// Returns the latest value from `StorageService` so the
  /// service never holds a stale snapshot. `null` when no
  /// working directory is configured (or when the underlying
  /// storage isn't injected, e.g. unit tests that don't go
  /// through `ToolService`).
  final String? Function()? _workingDirectoryLookup;

  /// SAF-backed working-directory backend (Android only). When
  /// set + [_isAndroid] is true, every working-dir op goes
  /// through this backend instead of `dart:io`. The native
  /// side handles the tree-URI grant + re-authorization flow
  /// internally; this class just translates the result.
  final WorkingDirBackend? _workingDirBackend;

  /// True when the host platform is Android. Used to gate
  /// the SAF-backend path. iOS keeps `dart:io` against the
  /// app sandbox; desktop keeps `dart:io` against the working
  /// directory path.
  final bool _isAndroid;

  @override
  String? get workingDirectory {
    final raw = _workingDirectoryLookup?.call();
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  /// True when the SAF-backed backend should handle working-dir
  /// ops. Requires both platform + injected backend - tests
  /// that pass `isAndroid: true` without a backend fall
  /// through to `dart:io` (which fails on Android in
  /// production but exercises the desktop code path in CI).
  bool get _useSaf => _isAndroid && _workingDirBackend != null;

  /// Convert a `working://<rel>` or bare-relative path into a
  /// `relPath` suitable for the native side. Throws
  /// [FileServiceError] for picker:// inputs and for
  /// bare-relative inputs when no working directory is
  /// configured.
  String _toRelPath(String input) {
    if (isPickerPath(input)) {
      throw FileServiceError(
        'internal: _toRelPath should not see picker:// paths',
      );
    }
    final working = _resolveWorkingPath(input);
    if (working == null) {
      throw FileServiceError(
        'invalid path: $input '
        '(expected picker://<id> or a relative path inside the '
        'configured working directory)',
      );
    }
    // Build the model-friendly `relPath` so the native side
    // can echo it back in listDir / readAttr responses.
    if (isWorkingPath(input)) {
      // Strip the `working://` prefix.
      final body = input.substring('working://'.length);
      if (body.isEmpty) return '';
      if (body.startsWith('/')) {
        // `working:///abs/path` — turn the abs path back into
        // a path that's relative to the working dir. Falls
        // through to bare-relative (relPath is empty) when the
        // abs path equals the working dir root.
        return _absToRel(body);
      }
      return body;
    }
    // Bare relative path: same as input, no prefix.
    return input;
  }

  String _absToRel(String abs) {
    final base = p.normalize(workingDirectory ?? '');
    if (base.isEmpty) return abs;
    final sep = Platform.pathSeparator;
    final normAbs = p.normalize(abs);
    if (normAbs == base) return '';
    final prefix = '$base$sep';
    if (!normAbs.startsWith(prefix)) return abs;
    return normAbs.substring(prefix.length);
  }

  /// Surface a `WorkingDirCancelledException` as a friendly
  /// [FileServiceError] so the model gets a clear hint.
  Never _translateCancel() {
    throw FileServiceError(
      'working directory access was denied by the user; '
      'ask the user to re-pick a folder via the chat toolbar',
    );
  }

  @override
  Future<({String path, String treeUri})?> pickWorkingDirectory() async {
    if (_workingDirBackend == null) {
      throw const FileServiceNotSupportedError();
    }
    try {
      return await _workingDirBackend.pickWorkingDirectory();
    } on WorkingDirCancelledException {
      return null;
    } on NotImplementedWorkingDirOp {
      throw const FileServiceNotSupportedError();
    }
  }

  /// Async equivalent of `FileSystemEntity.typeSync` that doesn't
  /// cache and therefore agrees with the subsequent
  /// `Directory.list()` call about whether the path actually
  /// exists on Windows (where the sync stat can briefly return
  /// `directory` for a path that the async list API then sees
  /// as missing).
  Future<FileSystemEntityType?> _statType(String resolved) async {
    try {
      // File.stat/.statSync doesn't reuse FileSystemEntity.stat
      // (which doesn't exist as an instance member). Probe as
      // a directory first; fall through to file.
      if (await Directory(resolved).exists()) {
        return FileSystemEntityType.directory;
      }
      if (await File(resolved).exists()) {
        return FileSystemEntityType.file;
      }
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Lists the immediate children of [resolved]. Uses the
  /// synchronous variant (`listSync`) to avoid a Windows-
  /// specific race where `Directory.list()` can briefly report
  /// `PathNotFoundException` for a directory that was created
  /// moments earlier in the same event-loop turn - even though
  /// `existsSync` reports `true` for the same path. The sync
  /// call is atomic at the OS level.
  Future<List<FileSystemEntity>> _listResolvedDir(String resolved) async {
    return Directory(resolved).listSync(followLinks: false);
  }

  /// Resolves a `working://<rel>` URI or a bare relative path
  /// against the user-selected working directory. Returns the
  /// absolute on-disk path.
  ///
  /// Throws [FileServiceError] when:
  ///   * no working directory is configured (the user hasn't
  ///     authorized one — fail loud, don't silently fall back)
  ///   * the resolved path escapes the working directory
  ///     (sandbox-escape protection via `..` rejection)
  ///
  /// Returns `null` when [input] doesn't look like a working
  /// directory path (has an unknown scheme, is absolute, etc.)
  /// - callers use this signal to decide whether to surface an
  /// "invalid path" error.
  String? _resolveWorkingPath(String input) {
    // Anything with a `picker://` / well-known absolute scheme
    // belongs to another branch - not us.
    if (isPickerPath(input)) return null;
    if (input.startsWith('http://') ||
        input.startsWith('https://') ||
        input.startsWith('content://') ||
        input.startsWith('file://')) {
      return null;
    }
    // Absolute paths (e.g. /storage/emulated/0/foo) are NOT
    // resolved against the working directory on mobile — the
    // model must use a relative path or `working://<rel>` so the
    // sandbox-escape check can verify the resolution. Matches
    // the existing "model never sees raw OS paths" policy.
    if (p.isAbsolute(input)) return null;

    final workingDir = workingDirectory;
    if (workingDir == null) {
      throw const FileServiceError(
        'no working directory configured on mobile; '
        'use action=pick to open the system file picker, or pick a '
        'folder via the chat toolbar first',
      );
    }
    final baseNorm = p.normalize(workingDir);

    final parsed = parseWorkingPath(input);
    // If the input had no scheme, treat the whole thing as
    // relative segments. Empty input resolves to the working
    // directory itself (used by `list_dir path=""`).
    final segments =
        parsed?.segments ?? (input.isEmpty ? const [] : _splitRel(input));

    String joined;
    if (parsed?.absoluteOverride != null) {
      // `working:///abs/path` — accept only if it stays inside
      // the working directory. Lets the model pass through a
      // known-safe absolute path.
      joined = p.normalize(parsed!.absoluteOverride!);
    } else {
      joined = segments.isEmpty
          ? baseNorm
          : p.normalize(p.join(baseNorm, p.joinAll(segments)));
    }

    final sep = Platform.pathSeparator;
    if (joined != baseNorm && !joined.startsWith('$baseNorm$sep')) {
      throw FileServiceError('path escapes the working directory: $input');
    }
    return joined;
  }

  /// Splits a forward-slash relative path into segments,
  /// filtering empty pieces. Backslashes are not expected on
  /// mobile paths but we tolerate them so a Windows-style
  /// input doesn't crash the resolver.
  static List<String> _splitRel(String rel) {
    return rel
        .split(RegExp(r'[/\\]'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  /// Resolves a path that should hit the local filesystem (i.e.
  /// not a `picker://<id>`) to an absolute on-disk path. The only
  /// supported form is a relative path / `working://` URI inside
  /// the configured working directory.
  ///
  /// Throws [FileServiceError] for inputs that don't match the
  /// working-directory scheme, or when no working directory is
  /// configured.
  Future<String> _resolveToDiskPath(String input) async {
    final workingResolved = _resolveWorkingPath(input);
    if (workingResolved != null) return workingResolved;
    throw FileServiceError(
      'invalid path: $input '
      '(expected picker://<id> or a relative path inside the '
      'configured working directory)',
    );
  }

  @override
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false}) async {
    final raw = await _backend.pick(mimeType: mimeType, readOnly: readOnly);
    if (raw == null) return null;
    if (raw['cancelled'] == true) return null;
    return PickedFile.fromJson(raw);
  }

  @override
  Future<void> release(String id) => _backend.release(id);

  @override
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024}) async {
    if (isPickerPath(path)) {
      final id = pickerIdOf(path)!;
      return _backend.read(id, maxBytes: maxBytes);
    }
    if (_useSaf) {
      try {
        final bytes = await _workingDirBackend!.readRel(
          _toRelPath(path),
          maxBytes: maxBytes,
        );
        if (bytes.length > maxBytes) {
          throw FileServiceError(
            'file too large: ${bytes.length} bytes (limit: $maxBytes); '
            'raise max_bytes if you really need it',
          );
        }
        return bytes;
      } on WorkingDirCancelledException {
        _translateCancel();
      }
    }
    final resolved = await _resolveToDiskPath(path);
    final file = File(resolved);
    if (!await file.exists()) {
      throw FileServiceError('file not found: $path');
    }
    final length = await file.length();
    if (length > maxBytes) {
      throw FileServiceError(
        'file too large: $length bytes (limit: $maxBytes); '
        'raise max_bytes if you really need it',
      );
    }
    return file.readAsBytes();
  }

  @override
  Future<void> write(
    String path,
    List<int> bytes, {
    bool append = false,
  }) async {
    if (isPickerPath(path)) {
      if (append) {
        throw FileServiceError(
          'append is not supported on picker://<id> paths; '
          'read + write instead',
        );
      }
      final id = pickerIdOf(path)!;
      return _backend.write(id, bytes);
    }
    if (_useSaf) {
      try {
        return await _workingDirBackend!.writeRel(
          _toRelPath(path),
          Uint8List.fromList(bytes),
          append: append,
        );
      } on WorkingDirCancelledException {
        _translateCancel();
      }
    }
    final resolved = await _resolveToDiskPath(path);
    final file = File(resolved);
    if (append && !await file.exists()) {
      throw FileServiceError('cannot append: file not found: $path');
    }
    // Sync create + write; the async variants have been seen to
    // race with the subsequent Directory.list() call on Windows
    // (the metadata snapshot for the freshly-created parent
    // dir can briefly appear stale to the async list path).
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      bytes,
      mode: append ? FileMode.append : FileMode.write,
      flush: true,
    );
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    if (isPickerPath(path)) {
      throw FileServiceError(
        'delete is not allowed on picker://<id> paths; '
        'use release(id) to drop the local handle instead',
      );
    }
    if (_useSaf) {
      try {
        return await _workingDirBackend!.deleteRel(
          _toRelPath(path),
          recursive: recursive,
        );
      } on WorkingDirCancelledException {
        _translateCancel();
      }
    }
    final resolved = await _resolveToDiskPath(path);
    final resolvedType = await _statType(resolved);
    if (resolvedType == null) {
      throw FileServiceError('path not found: $path');
    }
    if (resolvedType == FileSystemEntityType.directory) {
      if (!recursive) {
        final entries = await _listResolvedDir(resolved);
        if (entries.isNotEmpty) {
          throw FileServiceError(
            'directory is not empty; set recursive=true to delete non-empty directories',
          );
        }
      }
      await Directory(resolved).delete(recursive: recursive);
    } else {
      await File(resolved).delete();
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    if (isPickerPath(from) || isPickerPath(to)) {
      throw FileServiceError('rename is not allowed on picker://<id> paths');
    }
    if (_useSaf) {
      try {
        return await _workingDirBackend!.renameRel(
          _toRelPath(from),
          _toRelPath(to),
        );
      } on WorkingDirCancelledException {
        _translateCancel();
      }
    }
    final fromResolved = await _resolveToDiskPath(from);
    final toResolved = await _resolveToDiskPath(to);
    final srcType = FileSystemEntity.typeSync(fromResolved);
    if (srcType == FileSystemEntityType.notFound) {
      throw FileServiceError('path not found: $from');
    }
    final dstType = FileSystemEntity.typeSync(toResolved);
    if (dstType != FileSystemEntityType.notFound) {
      throw FileServiceError('destination already exists: $to');
    }
    if (srcType == FileSystemEntityType.directory) {
      await Directory(fromResolved).rename(toResolved);
    } else {
      await File(fromResolved).rename(toResolved);
    }
  }

  @override
  Future<List<FileEntry>> listDir(String path, {bool recursive = false}) async {
    if (isPickerPath(path)) {
      throw FileServiceError(
        'list_dir is not allowed on picker://<id> paths; '
        'picked files have no parent directory you can browse',
      );
    }
    if (_useSaf) {
      try {
        final entries = await _workingDirBackend!.listRel(
          _toRelPath(path),
          recursive: recursive,
        );
        // The backend may return an unmodifiable list
        // (e.g. when it hits a `const []` short-circuit in
        // tests), so build a mutable copy before sorting.
        final sorted = [...entries];
        sorted.sort((a, b) {
          final aDir = a.isDirectory ? 0 : 1;
          final bDir = b.isDirectory ? 0 : 1;
          if (aDir != bDir) return aDir.compareTo(bDir);
          return a.name.compareTo(b.name);
        });
        return sorted;
      } on WorkingDirCancelledException {
        _translateCancel();
      }
    }
    final resolved = await _resolveToDiskPath(path);
    final dir = Directory(resolved);
    if (!await dir.exists()) {
      throw FileServiceError('directory not found: $path');
    }
    // Surface back the model-friendly `working://` scheme so the
    // model can immediately re-use the path on follow-up turns.
    final workingBaseNorm = p.normalize(workingDirectory ?? '');
    const maxEntries = 200;
    final out = <FileEntry>[];
    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (out.length >= maxEntries) break;
      final stat = entity.statSync();
      // `path` here is the absolute disk path. `p.basename` is
      // more reliable than `entity.uri.pathSegments.lastOrNull`
      // (which can be empty for a Directory whose URL has a
      // trailing slash).
      final name = p.basename(entity.path);
      out.add(
        FileEntry(
          name: name,
          path: _absoluteToWorkingScheme(
            absolute: entity.path,
            workingBaseNorm: workingBaseNorm,
          ),
          isDirectory: entity is Directory,
          size: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    out.sort((a, b) {
      final aDir = a.isDirectory ? 0 : 1;
      final bDir = b.isDirectory ? 0 : 1;
      if (aDir != bDir) return aDir.compareTo(bDir);
      return a.name.compareTo(b.name);
    });
    return out;
  }

  @override
  Future<FileAttrs> readAttr(String path) async {
    if (isPickerPath(path)) {
      final id = pickerIdOf(path)!;
      final raw = await _backend.readAttr(id);
      return FileAttrs(
        path: path,
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
    if (_useSaf) {
      try {
        return await _workingDirBackend!.readAttrRel(_toRelPath(path));
      } on WorkingDirCancelledException {
        _translateCancel();
      }
    }
    final resolved = await _resolveToDiskPath(path);
    final type = FileSystemEntity.typeSync(resolved);
    if (type == FileSystemEntityType.notFound) {
      throw FileServiceError('path not found: $path');
    }
    final stat = File(resolved).statSync();
    return FileAttrs(
      path: path,
      type: _typeName(type),
      size: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
      accessedMs: stat.accessed.millisecondsSinceEpoch,
      changedMs: stat.changed.millisecondsSinceEpoch,
      isDirectory: type == FileSystemEntityType.directory,
      isFile: type == FileSystemEntityType.file,
      isLink: type == FileSystemEntityType.link,
    );
  }

  static String _typeName(FileSystemEntityType t) {
    if (t == FileSystemEntityType.file) return 'file';
    if (t == FileSystemEntityType.directory) return 'directory';
    if (t == FileSystemEntityType.link) return 'link';
    return 'other';
  }

  /// Reconstructs a model-friendly `working://` path from an
  /// absolute on-disk path produced by [listDir]. The model can
  /// immediately re-use the returned path on follow-up turns.
  static String _absoluteToWorkingScheme({
    required String absolute,
    required String workingBaseNorm,
  }) {
    final norm = p.normalize(absolute);
    if (workingBaseNorm.isEmpty) return norm;
    final sep = Platform.pathSeparator;
    if (norm == workingBaseNorm) return 'working://';
    final prefix = '$workingBaseNorm$sep';
    if (!norm.startsWith(prefix)) return norm;
    final rel = norm.substring(prefix.length);
    return 'working://${p.posix.joinAll(p.split(rel))}';
  }

  // -------- Edit --------

  static const int _editReadMaxBytes = 32 * 1024 * 1024;

  @override
  Future<EditResult> edit(String path, List<EditOp> edits) async {
    try {
      final bytes = await read(path, maxBytes: _editReadMaxBytes);
      final decoded = TextFileData.decode(bytes);
      final application = applyLineEdits(
        source: decoded.text,
        edits: edits,
        sizeBefore: bytes.length,
      );
      if (!application.result.ok) return application.result;

      final updatedBytes = TextFileData(
        text: application.text,
        encoding: decoded.encoding,
      ).encode();
      await write(path, updatedBytes);
      final refreshedBytes = await read(path, maxBytes: _editReadMaxBytes);
      if (!_bytesEqual(updatedBytes, refreshedBytes)) {
        return EditResult.error(
          code: 'WRITE_VERIFY_FAILED',
          message: 'file content did not match the requested edit after write',
          sizeBefore: bytes.length,
          sizeAfter: refreshedBytes.length,
        );
      }
      return EditResult.success(
        applied: edits.length,
        sizeBefore: bytes.length,
        sizeAfter: updatedBytes.length,
        diff: application.result.diff,
      );
    } on FormatException catch (e) {
      return EditResult.error(
        code: 'UNSUPPORTED_TEXT_ENCODING',
        message: e.message,
      );
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Thrown by [FileService] operations when the user-facing
/// action cannot be completed. The chat provider surfaces this
/// as a tool failure to the model.
class FileServiceError implements Exception {
  const FileServiceError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Thrown when the platform doesn't have a file service
/// (web). The chat provider surfaces this as a tool failure
/// — the model gets a clear "not supported on this platform"
/// hint, not a stack trace.
class FileServiceNotSupportedError extends FileServiceError {
  const FileServiceNotSupportedError()
    : super('file service is not supported on this platform');
}
