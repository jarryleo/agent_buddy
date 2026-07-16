import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/picked_file.dart';
import 'file_service.dart';

/// Backend that talks to the native bridge for picker-backed ops
/// (`pick` / `release` / read-write on `picker://<id>` paths).
///
/// Kept as a separate class so it can be swapped in tests with a
/// pure-Dart fake.
abstract class PickerFileBackend {
  Future<Map<String, dynamic>?> pick({
    String? mimeType,
    bool readOnly = false,
  });

  Future<void> release(String id);

  Future<List<int>> read(String id, {required int maxBytes});

  Future<void> write(
    String id,
    List<int> bytes, {
    bool append = false,
  });

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
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'pick',
        {
          'mime_type': mimeType,
          'read_only': readOnly,
        },
      );
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
  Future<void> write(
    String id,
    List<int> bytes, {
    bool append = false,
  }) async {
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

/// Production [FileService]: sandbox paths via `path_provider`
/// + `dart:io`; picker paths via [PickerFileBackend].
class FileServiceImpl implements FileService {
  FileServiceImpl({
    PickerFileBackend? backend,
    Future<Directory>? overrideDocs,
    Future<Directory>? overrideTemp,
    Future<Directory>? overrideSupport,
  }) : _backend = backend ?? MethodChannelPickerBackend(),
       _overrideDocs = overrideDocs,
       _overrideTemp = overrideTemp,
       _overrideSupport = overrideSupport;

  final PickerFileBackend _backend;
  final Future<Directory>? _overrideDocs;
  final Future<Directory>? _overrideTemp;
  final Future<Directory>? _overrideSupport;

  Future<Directory> _resolveRoot(AppSandbox root) async {
    switch (root) {
      case AppSandbox.documents:
        return _overrideDocs ?? getApplicationDocumentsDirectory();
      case AppSandbox.temp:
        return _overrideTemp ?? getTemporaryDirectory();
      case AppSandbox.support:
        return _overrideSupport ?? getApplicationSupportDirectory();
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
  /// moments earlier in the same event-loop turn — even though
  /// `existsSync` reports `true` for the same path. The sync
  /// call is atomic at the OS level.
  Future<List<FileSystemEntity>> _listResolvedDir(String resolved) async {
    return Directory(resolved).listSync(followLinks: false);
  }

  /// Resolves a `app://<root>/...` URI to a real absolute path,
  /// rejecting any `..` segment that would escape the sandbox.
  Future<String?> _resolveAppPath(String input) async {
    final parsed = parseAppPath(input);
    if (parsed == null) return null;
    final base = (await _resolveRoot(parsed.root)).path;
    final baseNorm = p.normalize(base);
    if (parsed.segments.isEmpty) return baseNorm;
    final joined = p.normalize(p.join(baseNorm, p.joinAll(parsed.segments)));
    // Reject sandbox escape: the resolved path must still be
    // inside the requested root.
    final sep = Platform.pathSeparator;
    if (joined != baseNorm && !joined.startsWith('$baseNorm$sep')) {
      throw FileServiceError('path escapes the sandbox: $input');
    }
    return joined;
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
    final resolved = await _resolveAppPath(path);
    if (resolved == null) {
      throw FileServiceError('invalid path: $path (expected app:// or picker://)');
    }
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
    final resolved = await _resolveAppPath(path);
    if (resolved == null) {
      throw FileServiceError('invalid path: $path (expected app:// or picker://)');
    }
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
    final resolved = await _resolveAppPath(path);
    if (resolved == null) {
      throw FileServiceError('invalid path: $path (expected app://)');
    }
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
      throw FileServiceError(
        'rename is not allowed on picker://<id> paths',
      );
    }
    final fromResolved = await _resolveAppPath(from);
    final toResolved = await _resolveAppPath(to);
    if (fromResolved == null || toResolved == null) {
      throw FileServiceError('invalid path (expected app://)');
    }
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
    final parsed = parseAppPath(path);
    if (parsed == null) {
      throw FileServiceError('invalid path: $path (expected app://)');
    }
    final base = (await _resolveRoot(parsed.root)).path;
    final baseNorm = p.normalize(base);
    final dir = Directory(baseNorm);
    if (!await dir.exists()) {
      throw FileServiceError('directory not found: $path');
    }
    const maxEntries = 200;
    final out = <FileEntry>[];
    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      if (out.length >= maxEntries) break;
      final stat = entity.statSync();
      // `path` here is the absolute disk path under one of our
      // sandbox roots. `p.basename` is more reliable than
      // `entity.uri.pathSegments.lastOrNull` (which can be
      // empty for a Directory whose URL has a trailing slash).
      final name = p.basename(entity.path);
      out.add(
        FileEntry(
          name: name,
          path: _absoluteToApp(entity.path, parsed.root, baseNorm),
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
    final resolved = await _resolveAppPath(path);
    if (resolved == null) {
      throw FileServiceError('invalid path: $path (expected app:// or picker://)');
    }
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

  /// Reconstructs an `app://<root>/...` path from an absolute
  /// on-disk path that lives under [baseNorm] (the resolved
  /// root for [root]).
  static String _absoluteToApp(String absolute, AppSandbox root, String baseNorm) {
    final norm = p.normalize(absolute);
    final scheme = 'app://${_schemeHostFor(root)}';
    if (norm == baseNorm) return '$scheme/';
    final prefix = '$baseNorm${Platform.pathSeparator}';
    if (!norm.startsWith(prefix)) return absolute; // shouldn't happen
    final rel = norm.substring(prefix.length);
    return '$scheme/${p.posix.joinAll(p.split(rel))}';
  }

  static String _schemeHostFor(AppSandbox root) {
    switch (root) {
      case AppSandbox.documents:
        return 'documents';
      case AppSandbox.temp:
        return 'temp';
      case AppSandbox.support:
        return 'support';
    }
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
