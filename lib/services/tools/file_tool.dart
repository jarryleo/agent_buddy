import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/file_service.dart';
import '../tool_service.dart';
import 'tool_base.dart';

/// Built-in `file` tool.
///
/// **Desktop (Windows / macOS / Linux)** — unchanged. The tool
/// talks to `dart:io` directly against the user's working
/// directory or any absolute path they pass. This matches the
/// pre-mobile behavior 1:1.
///
/// **Mobile (Android / iOS)** — delegates to [FileService] over
/// a MethodChannel. The model only ever sees two path schemes:
///   * `picker://<id>` for files the user picked via the
///     system file picker (no Android / iOS runtime permission
///     needed — SAF / `UIDocumentPickerViewController` handle
///     per-URI grants themselves).
///   * `working://<rel>` (or a bare relative path) for files
///     inside the user-selected working directory. The model
///     defaults to operating on the working directory or on
///     picked files - there are no other sandbox roots.
///
/// **Permission flow** — the only operation that needs user
/// action is `pick`. The bridge parks the Dart-side call until
/// the user picks / cancels / the OS dismisses the picker, so
/// the model's tool future never returns a transient error
/// before the user has had a chance to answer. A user cancel
/// comes back as `{ok:false, cancelled:true}` (not an
/// exception) so the model can pivot to a different approach.
class FileTool extends ToolBase {
  @override
  String get id => 'file';
  @override
  String get name => '文件';

  static const String _desktopDescription =
      '管理电脑文件(读/写/删/改名/列目录/查属性)。仅 Windows / macOS / Linux 可用。';

  /// Mobile description overrides [description] only when the
  /// tool is being built on a mobile platform — the schema
  /// captures the mobile-specific actions.
  @override
  String get description {
    if (isMobileForRuntime()) {
      return '管理设备文件。手机: 默认操作工作目录(相对路径或 working://),或用 action=pick 打开系统选择器读/写手机上的任意文件(无需 Android 权限)。电脑走原桌面端逻辑。';
    }
    return _desktopDescription;
  }

  @override
  bool get isSupportedOnCurrentPlatform =>
      isDesktopForRuntime() || isMobileForRuntime();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    if (isMobileForRuntime()) return _mobileSchema();
    return _desktopSchema();
  }

  Map<String, dynamic> _desktopSchema() => {
    'type': 'function',
    'function': {
      'name': 'file',
      'description': _desktopDescription,
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'read',
              'read_attr',
              'write',
              'append',
              'delete',
              'rename',
              'list_dir',
            ],
            'description':
                '操作: read(读文本)/read_attr(查属性)/write(覆盖写)/append(追加)/delete(删)/rename(重命名/移动)/list_dir(列目录)',
          },
          'path': {
            'type': 'string',
            'description': '文件或目录路径。相对路径基于用户选择的模型工作目录。',
          },
          'content': {
            'type': 'string',
            'description': 'write 时必填(新内容),append 时可填(追加内容)',
          },
          'new_path': {'type': 'string', 'description': 'rename 时必填(新路径)'},
          'recursive': {
            'type': 'boolean',
            'description':
                'delete 时是否递归删目录(默认 false,目录非空需 true);list_dir 时是否递归列子目录(默认 false)',
            'default': false,
          },
        },
        'required': ['action', 'path'],
      },
    },
  };

  Map<String, dynamic> _mobileSchema() => {
    'type': 'function',
    'function': {
      'name': 'file',
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'pick',
              'release',
              'read',
              'read_attr',
              'write',
              'append',
              'delete',
              'rename',
              'list_dir',
            ],
            'description':
                '操作: pick(打开系统文件选择器,会弹出系统 UI)/release(释放 picker id)/read(读)/read_attr(查属性)/write(覆盖写)/append(追加)/delete(删,仅限工作目录)/rename(改名,仅限工作目录)/list_dir(列目录,仅限工作目录)',
          },
          'path': {
            'type': 'string',
            'description':
                '文件路径。选过的文件: picker://<id>;工作目录用 working://<相对路径>(如 working://foo/bar.txt)或裸相对路径(如 foo/bar.txt),都基于工作目录解析,类似桌面端的相对路径。',
          },
          'content': {
            'type': 'string',
            'description': 'write/append 必填(新内容或追加内容)',
          },
          'new_path': {
            'type': 'string',
            'description': 'rename 时必填(目标路径,working:// 或同工作目录下的裸相对路径)',
          },
          'recursive': {
            'type': 'boolean',
            'description': 'delete 是否递归(默认 false);list_dir 是否递归(默认 false)',
            'default': false,
          },
          'mime_type': {
            'type': 'string',
            'description':
                'pick 可选: 限定选择类型,如 "text/*" / "image/*" / "application/pdf"',
          },
          'id': {
            'type': 'string',
            'description': 'release 必填: pick 拿到的 picker id(不含 picker://)',
          },
          'max_bytes': {
            'type': 'integer',
            'description': 'read 可选: 字节上限,默认 2097152(2MB)',
            'default': 2 * 1024 * 1024,
            'minimum': 1024,
            'maximum': 32 * 1024 * 1024,
          },
        },
        'required': ['action'],
      },
    },
  };

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    if (isMobileForRuntime()) {
      return _executeMobile(args, services);
    }
    return _executeDesktop(args, services);
  }

  // -------- Mobile (Android / iOS) --------

  Future<String> _executeMobile(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final action = (args['action'] as String? ?? '').trim();
    if (action.isEmpty) {
      throw ToolException('"action" is required');
    }

    final file = services.file;
    switch (action) {
      case 'pick':
        final mimeType = args['mime_type'] as String?;
        return _pick(file, mimeType: mimeType);

      case 'release':
        final id = (args['id'] as String? ?? '').trim();
        if (id.isEmpty) {
          throw ToolException('"id" is required for release');
        }
        await file.release(id);
        return jsonEncode({'action': 'release', 'id': id, 'ok': true});

      case 'read':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for read');
        }
        final maxBytes =
            (args['max_bytes'] as num?)?.toInt() ?? 2 * 1024 * 1024;
        final bytes = await file.read(path, maxBytes: maxBytes);
        final envelope = _buildReadEnvelope(
          path: path,
          bytes: bytes,
          encoding: 'binary',
        );
        // Best-effort: if it's UTF-8, surface as text for the
        // model; otherwise keep the binary marker.
        try {
          final text = utf8.decode(bytes);
          envelope['encoding'] = 'utf-8';
          envelope['content'] = text;
        } on FormatException {
          envelope['content'] = '[binary file, ${bytes.length} bytes]';
        }
        return jsonEncode(envelope);

      case 'read_attr':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for read_attr');
        }
        final attrs = await file.readAttr(path);
        return jsonEncode({'action': 'read_attr', ...attrs.toJson()});

      case 'write':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for write');
        }
        final content = args['content'] as String? ?? '';
        await file.write(path, utf8.encode(content));
        return jsonEncode({
          'action': 'write',
          'path': path,
          'size': utf8.encode(content).length,
          'ok': true,
        });

      case 'append':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for append');
        }
        final content = args['content'] as String? ?? '';
        await file.write(path, utf8.encode(content), append: true);
        return jsonEncode({
          'action': 'append',
          'path': path,
          'size': utf8.encode(content).length,
          'ok': true,
        });

      case 'delete':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for delete');
        }
        if (isPickerPath(path)) {
          throw ToolException(
            'delete is not allowed on picker://<id> paths; '
            'use release(id) to drop the local handle instead',
          );
        }
        final recursive = args['recursive'] as bool? ?? false;
        await file.delete(path, recursive: recursive);
        return jsonEncode({'action': 'delete', 'path': path, 'ok': true});

      case 'rename':
        final from = (args['path'] as String? ?? '').trim();
        final to = (args['new_path'] as String? ?? '').trim();
        if (from.isEmpty || to.isEmpty) {
          throw ToolException('"path" and "new_path" are required for rename');
        }
        if (isPickerPath(from) || isPickerPath(to)) {
          throw ToolException('rename is not allowed on picker://<id> paths');
        }
        await file.rename(from, to);
        return jsonEncode({
          'action': 'rename',
          'path': from,
          'new_path': to,
          'ok': true,
        });

      case 'list_dir':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for list_dir');
        }
        if (isPickerPath(path)) {
          throw ToolException(
            'list_dir is not allowed on picker://<id> paths; '
            'picked files have no parent directory you can browse',
          );
        }
        final recursive = args['recursive'] as bool? ?? false;
        final entries = await file.listDir(path, recursive: recursive);
        final entryMaps = entries.map((e) => e.toJson()).toList();
        return jsonEncode({
          'action': 'list_dir',
          'path': path,
          'count': entryMaps.length,
          'truncated': entryMaps.length >= 200,
          'recursive': recursive,
          'entries': entryMaps,
        });

      default:
        throw ToolException(
          'unknown action: $action '
          '(expected pick/release/read/read_attr/write/append/delete/rename/list_dir)',
        );
    }
  }

  Future<String> _pick(FileService file, {String? mimeType}) async {
    final picked = await file.pick(mimeType: mimeType);
    if (picked == null) {
      // User cancelled — soft signal, not a failure.
      return jsonEncode({'action': 'pick', 'ok': false, 'cancelled': true});
    }
    return jsonEncode({
      'action': 'pick',
      'ok': true,
      'cancelled': false,
      'items': [picked.toJson()],
    });
  }

  Map<String, dynamic> _buildReadEnvelope({
    required String path,
    required List<int> bytes,
    required String encoding,
  }) {
    return {
      'action': 'read',
      'path': path,
      'size': bytes.length,
      'encoding': encoding,
      'content': '',
    };
  }

  // -------- Desktop (Windows / macOS / Linux) --------

  Future<String> _executeDesktop(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final action = args['action'] as String? ?? '';
    final rawPath = (args['path'] as String? ?? '').trim();
    if (rawPath.isEmpty) {
      throw ToolException('"path" is required');
    }
    final path = _resolveDesktopPath(rawPath, services);

    switch (action) {
      case 'read':
        return _readDesktop(path);
      case 'read_attr':
        return _readAttrDesktop(path);
      case 'write':
        final content = args['content'] as String? ?? '';
        return _writeDesktop(path, content);
      case 'append':
        final content = args['content'] as String? ?? '';
        return _appendDesktop(path, content);
      case 'delete':
        final recursive = args['recursive'] as bool? ?? false;
        return _deleteDesktop(path, recursive);
      case 'rename':
        final rawNewPath = (args['new_path'] as String? ?? '').trim();
        if (rawNewPath.isEmpty) {
          throw ToolException('"new_path" is required for rename');
        }
        return _renameDesktop(path, _resolveDesktopPath(rawNewPath, services));
      case 'list_dir':
        final recursive = args['recursive'] as bool? ?? false;
        return _listDirDesktop(path, recursive);
      default:
        throw ToolException(
          'unknown action: $action (expected read/read_attr/write/append/delete/rename/list_dir)',
        );
    }
  }

  String _resolveDesktopPath(String input, ToolService services) {
    if (p.isAbsolute(input)) return p.normalize(input);
    final workingDirectory = services.workingDirectory;
    if (workingDirectory == null || workingDirectory.isEmpty) {
      return p.normalize(input);
    }
    return p.normalize(p.join(workingDirectory, input));
  }

  Future<String> _readDesktop(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ToolException('file not found: $path');
    }
    try {
      final bytes = await file.readAsBytes();
      try {
        final text = utf8.decode(bytes);
        return jsonEncode({
          'action': 'read',
          'path': path,
          'size': bytes.length,
          'encoding': 'utf-8',
          'content': text,
        });
      } on FormatException {
        return jsonEncode({
          'action': 'read',
          'path': path,
          'size': bytes.length,
          'encoding': 'binary',
          'content': '[binary file, ${bytes.length} bytes]',
        });
      }
    } catch (e) {
      throw ToolException('error reading file: $e');
    }
  }

  Future<String> _readAttrDesktop(String path) async {
    final entityType = FileSystemEntity.typeSync(path);
    if (entityType == FileSystemEntityType.notFound) {
      throw ToolException('path not found: $path');
    }
    try {
      final stat = File(path).statSync();
      return jsonEncode({
        'action': 'read_attr',
        'path': path,
        'type': _typeName(entityType),
        'size': stat.size,
        'modified_ms': stat.modified.millisecondsSinceEpoch,
        'accessed_ms': stat.accessed.millisecondsSinceEpoch,
        'changed_ms': stat.changed.millisecondsSinceEpoch,
        'is_directory': entityType == FileSystemEntityType.directory,
        'is_file': entityType == FileSystemEntityType.file,
        'is_link': entityType == FileSystemEntityType.link,
      });
    } catch (e) {
      throw ToolException('error reading attributes: $e');
    }
  }

  static String _typeName(FileSystemEntityType t) {
    if (t == FileSystemEntityType.file) return 'file';
    if (t == FileSystemEntityType.directory) return 'directory';
    if (t == FileSystemEntityType.link) return 'link';
    return 'other';
  }

  Future<String> _writeDesktop(String path, String content) async {
    try {
      final file = File(path);
      await file.writeAsString(content);
      return jsonEncode({
        'action': 'write',
        'path': path,
        'size': content.length,
        'ok': true,
      });
    } catch (e) {
      throw ToolException('error writing file: $e');
    }
  }

  Future<String> _appendDesktop(String path, String content) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw ToolException('file not found: $path');
      }
      await file.writeAsString(content, mode: FileMode.append);
      return jsonEncode({
        'action': 'append',
        'path': path,
        'size': content.length,
        'ok': true,
      });
    } catch (e) {
      throw ToolException('error appending to file: $e');
    }
  }

  Future<String> _deleteDesktop(String path, bool recursive) async {
    try {
      final entityType = FileSystemEntity.typeSync(path);
      if (entityType == FileSystemEntityType.notFound) {
        throw ToolException('path not found: $path');
      }
      if (entityType == FileSystemEntityType.directory) {
        if (!recursive) {
          final dir = Directory(path);
          final isEmpty = await dir.list().isEmpty;
          if (!isEmpty) {
            throw ToolException(
              'directory is not empty; set recursive=true to delete non-empty directories',
            );
          }
        }
        await Directory(path).delete(recursive: recursive);
      } else {
        await File(path).delete();
      }
      return jsonEncode({'action': 'delete', 'path': path, 'ok': true});
    } on ToolException {
      rethrow;
    } catch (e) {
      throw ToolException('error deleting: $e');
    }
  }

  Future<String> _renameDesktop(String path, String newPath) async {
    try {
      final sourceType = FileSystemEntity.typeSync(path);
      if (sourceType == FileSystemEntityType.notFound) {
        throw ToolException('path not found: $path');
      }
      final destType = FileSystemEntity.typeSync(newPath);
      if (destType != FileSystemEntityType.notFound) {
        throw ToolException('destination already exists: $newPath');
      }
      if (sourceType == FileSystemEntityType.directory) {
        await Directory(path).rename(newPath);
      } else {
        await File(path).rename(newPath);
      }
      return jsonEncode({
        'action': 'rename',
        'path': path,
        'new_path': newPath,
        'ok': true,
      });
    } on ToolException {
      rethrow;
    } catch (e) {
      throw ToolException('error renaming: $e');
    }
  }

  Future<String> _listDirDesktop(String path, bool recursive) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      throw ToolException('directory not found: $path');
    }
    try {
      const maxEntries = 200;
      final entries = <Map<String, dynamic>>[];
      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entries.length >= maxEntries) break;
        final stat = entity.statSync();
        entries.add({
          'name': entity.uri.pathSegments.lastOrNull ?? entity.path,
          'path': entity.path,
          'type': entity is File
              ? 'file'
              : entity is Directory
              ? 'dir'
              : 'link',
          'size': stat.size,
          'modified_ms': stat.modified.millisecondsSinceEpoch,
        });
      }
      entries.sort((a, b) {
        final aDir = a['type'] == 'dir' ? 0 : 1;
        final bDir = b['type'] == 'dir' ? 0 : 1;
        if (aDir != bDir) return aDir.compareTo(bDir);
        return (a['name'] as String).compareTo(b['name'] as String);
      });
      return jsonEncode({
        'action': 'list_dir',
        'path': path,
        'count': entries.length,
        'truncated': entries.length >= maxEntries,
        'recursive': recursive,
        'entries': entries,
      });
    } catch (e) {
      throw ToolException('error listing directory: $e');
    }
  }
}
