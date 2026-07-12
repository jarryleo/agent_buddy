import 'dart:convert';
import 'dart:io';

import '../tool_service.dart';
import 'tool_base.dart';

class FileTool extends ToolBase {
  @override String get id => 'file';
  @override String get name => '文件';
  @override String get description => '管理电脑文件(读/写/删/改名/列目录/查属性)。仅 Windows / macOS / Linux 可用。';
  @override bool get isSupportedOnCurrentPlatform => isDesktop();

  @override Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'file', 'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['read', 'read_attr', 'write', 'append', 'delete', 'rename', 'list_dir'],
              'description': '操作: read(读文本)/read_attr(查属性)/write(覆盖写)/append(追加)/delete(删)/rename(重命名/移动)/list_dir(列目录)',
            },
            'path': {
              'type': 'string',
              'description': '文件或目录的绝对路径。Windows 用反斜杠,Unix 用正斜杠。',
            },
            'content': {
              'type': 'string',
              'description': 'write 时必填(新内容),append 时可填(追加内容)',
            },
            'new_path': {
              'type': 'string',
              'description': 'rename 时必填(新路径)',
            },
            'recursive': {
              'type': 'boolean',
              'description': 'delete 时是否递归删目录(默认 false,目录非空需 true);list_dir 时是否递归列子目录(默认 false)',
              'default': false,
            },
          },
          'required': ['action', 'path'],
        },
      },
    };
  }

  @override
  Future<String> execute(Map<String, dynamic> args, ToolService services) async {
    if (!isDesktop()) {
      throw ToolException('file tool is only supported on desktop (macOS / Windows / Linux)');
    }

    final action = args['action'] as String? ?? '';
    final path = (args['path'] as String? ?? '').trim();
    if (path.isEmpty) {
      throw ToolException('"path" is required');
    }

    switch (action) {
      case 'read':
        return _read(path);
      case 'read_attr':
        return _readAttr(path);
      case 'write':
        final content = args['content'] as String? ?? '';
        return _write(path, content);
      case 'append':
        final content = args['content'] as String? ?? '';
        return _append(path, content);
      case 'delete':
        final recursive = args['recursive'] as bool? ?? false;
        return _delete(path, recursive);
      case 'rename':
        final newPath = (args['new_path'] as String? ?? '').trim();
        if (newPath.isEmpty) {
          throw ToolException('"new_path" is required for rename');
        }
        return _rename(path, newPath);
      case 'list_dir':
        final recursive = args['recursive'] as bool? ?? false;
        return _listDir(path, recursive);
      default:
        throw ToolException(
          'unknown action: $action (expected read/read_attr/write/append/delete/rename/list_dir)',
        );
    }
  }

  Future<String> _read(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ToolException('file not found: $path');
    }
    try {
      final bytes = await file.readAsBytes();
      try {
        final text = utf8.decode(bytes);
        return jsonEncode({
          'action': 'read', 'path': path,
          'size': bytes.length, 'encoding': 'utf-8', 'content': text,
        });
      } on FormatException {
        return jsonEncode({
          'action': 'read', 'path': path,
          'size': bytes.length, 'encoding': 'binary',
          'content': '[binary file, ${bytes.length} bytes]',
        });
      }
    } catch (e) {
      throw ToolException('error reading file: $e');
    }
  }

  Future<String> _readAttr(String path) async {
    final entityType = FileSystemEntity.typeSync(path);
    if (entityType == FileSystemEntityType.notFound) {
      throw ToolException('path not found: $path');
    }
    try {
      final stat = File(path).statSync();
      return jsonEncode({
        'action': 'read_attr', 'path': path,
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

  Future<String> _write(String path, String content) async {
    try {
      final file = File(path);
      await file.writeAsString(content);
      return jsonEncode({
        'action': 'write', 'path': path, 'size': content.length, 'ok': true,
      });
    } catch (e) {
      throw ToolException('error writing file: $e');
    }
  }

  Future<String> _append(String path, String content) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw ToolException('file not found: $path');
      }
      await file.writeAsString(content, mode: FileMode.append);
      return jsonEncode({
        'action': 'append', 'path': path, 'size': content.length, 'ok': true,
      });
    } catch (e) {
      throw ToolException('error appending to file: $e');
    }
  }

  Future<String> _delete(String path, bool recursive) async {
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
      return jsonEncode({
        'action': 'delete', 'path': path, 'ok': true,
      });
    } on ToolException {
      rethrow;
    } catch (e) {
      throw ToolException('error deleting: $e');
    }
  }

  Future<String> _rename(String path, String newPath) async {
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
        'action': 'rename', 'path': path, 'new_path': newPath, 'ok': true,
      });
    } on ToolException {
      rethrow;
    } catch (e) {
      throw ToolException('error renaming: $e');
    }
  }

  Future<String> _listDir(String path, bool recursive) async {
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
        'action': 'list_dir', 'path': path,
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
