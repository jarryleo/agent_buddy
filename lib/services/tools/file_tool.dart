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
      '管理电脑文件(读/写/删/改名/列目录/查属性)。仅 Windows / macOS / Linux 可用。改代码优先用 action=edit(精确文本替换,旧 text 必须唯一,失败会返回诊断),read 支持 offset_lines/max_lines 分页+pattern 当 grep。';

  /// Mobile description overrides [description] only when the
  /// tool is being built on a mobile platform — the schema
  /// captures the mobile-specific actions.
  @override
  String get description {
    if (isMobileForRuntime()) {
      return '管理设备文件。手机: 默认操作工作目录(相对路径或 working://),或用 action=pick 打开系统选择器读/写手机上的任意文件(无需 Android 权限)。电脑走原桌面端逻辑。改代码优先用 action=edit(精确文本替换,旧 text 必须唯一),read 支持 offset_lines/max_lines 分页+pattern 当 grep。';
    }
    return _desktopDescription;
  }

  @override
  String get shortDescription => '文件读写改列删(改代码用 action=edit)';

  @override
  String get compactSchemaForModel {
    if (!isSupportedOnCurrentPlatform) return '';
    final mobile = isMobileForRuntime();
    final actions = mobile
        ? '''
- pick {mime_type?, read_only?}: 弹系统选择器;返回 {ok, picker_id, name, mime_type, size_bytes, encoding}。需用户操作,awaitUserAction=true
- release {picker_id}: 释放 picker_id 的 URI 授权
- read {path, max_bytes?, offset_lines?, max_lines?, pattern?}: path 可为 picker://<id>、working://<rel> 或相对路径
- read_attr {path}
- write {path, content, mode=overwrite|append?}
- edit {path, edits:[{old_text, new_text, global_replace?}]}: 精确替换;old_text 默认必须唯一
- append {path, content}
- list_dir {path} (仅 working://)
- delete / rename / list_dir (仅 working://)'''
        : '''
- read {path, max_bytes?, offset_lines?, max_lines?, pattern?}
- read_attr {path}
- write {path, content, mode=overwrite|append?}
- edit {path, edits:[{old_text, new_text, global_replace?}]}: 精确替换;old_text 默认必须唯一
- append {path, content}
- list_dir {path}
- delete {path}
- rename {path, new_path}''';

    return '''
path 形式 (mobile):
- picker://<id>        系统选择器返回的文件
- working://<rel>      用户选定的工作目录(默认;缺省时报"未配置工作目录")
- 裸相对路径           同 working://

公共参数:
- action (string, 必填): 见下方
- 其余参数按 action

actions:$actions

edit 返回:
- 成功: {action:"edit", applied:true, diff:[{matched_line,old_preview,new_preview,replacements}]}
- 失败: {action:"edit", applied:false, error_code:OLD_TEXT_NOT_FOUND|OLD_TEXT_NOT_UNIQUE|PATH_NOT_FOUND, near_matches?/candidates? 含 1-based 行号}

read 返回:
- 默认: 全文 + 行号前缀 "N|line"
- offset_lines + max_lines: 分页
- pattern: 命中行 + 上下 2 行,200 行上限
- 二进制: {encoding:"binary", content:"[binary file, N bytes]"}

约束:
- edit 一次提交多个 edits 时,**任何一个失败都不会写盘**(整批原子)
- edit 默认 old_text 必须唯一;批量改名传 global_replace=true
- new_text="" 等价于删除匹配块
- 所有路径禁止 .. 跳出工作目录
''';
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
              'edit',
              'write',
              'append',
              'delete',
              'rename',
              'list_dir',
            ],
            'description':
                '操作: read(读文本,可分页+grep)/read_attr(查属性)/edit(精确文本替换,改代码首选)/write(覆盖写)/append(追加)/delete(删)/rename(重命名/移动)/list_dir(列目录)',
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
          'offset_lines': {
            'type': 'integer',
            'minimum': 0,
            'default': 0,
            'description': 'read 可选: 从第 N 行(0-indexed)开始读,默认 0。',
          },
          'max_lines': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 2000,
            'default': 500,
            'description': 'read 可选: 最多返回多少行(默认 500, 上限 2000),避免一次读大文件塞满上下文。',
          },
          'pattern': {
            'type': 'string',
            'description':
                'read 可选: 当 grep 用,只返回含此字符串的行 + 前后 2 行上下文(每行带 1-indexed 行号)。',
          },
          'edits': {
            'type': 'array',
            'description':
                'edit 必填: 一组原子精确替换。每项含 old_text(必填,默认必须唯一)、new_text(空=删除)、global_replace(可选,默认 false)。失败时整批回滚,返回首个失败 edit 的诊断(位置/候选行号)。',
            'items': {
              'type': 'object',
              'properties': {
                'old_text': {
                  'type': 'string',
                  'description': '要替换的原文本(非空,默认必须唯一)。',
                },
                'new_text': {
                  'type': 'string',
                  'description': '替换后的文本(空字符串=删除匹配的块)。',
                  'default': '',
                },
                'global_replace': {
                  'type': 'boolean',
                  'description':
                      '是否替换全部匹配(默认 false,要求 old_text 唯一)。改名/批量替换时用 true。',
                  'default': false,
                },
              },
              'required': ['old_text'],
            },
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
              'edit',
              'write',
              'append',
              'delete',
              'rename',
              'list_dir',
            ],
            'description':
                '操作: pick(打开系统文件选择器,会弹出系统 UI)/release(释放 picker id)/read(读,可分页+grep)/read_attr(查属性)/edit(精确文本替换,改代码首选)/write(覆盖写)/append(追加)/delete(删,仅限工作目录)/rename(改名,仅限工作目录)/list_dir(列目录,仅限工作目录)',
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
          'offset_lines': {
            'type': 'integer',
            'minimum': 0,
            'default': 0,
            'description': 'read 可选: 从第 N 行(0-indexed)开始读,默认 0。',
          },
          'max_lines': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 2000,
            'default': 500,
            'description': 'read 可选: 最多返回多少行(默认 500, 上限 2000)。',
          },
          'pattern': {
            'type': 'string',
            'description':
                'read 可选: 当 grep 用,只返回含此字符串的行 + 前后 2 行上下文(每行带 1-indexed 行号)。',
          },
          'edits': {
            'type': 'array',
            'description': 'edit 必填: 一组原子精确替换(同桌面端 schema 的描述)。',
            'items': {
              'type': 'object',
              'properties': {
                'old_text': {
                  'type': 'string',
                  'description': '要替换的原文本(非空,默认必须唯一)。',
                },
                'new_text': {
                  'type': 'string',
                  'description': '替换后的文本(空字符串=删除)。',
                  'default': '',
                },
                'global_replace': {
                  'type': 'boolean',
                  'description': '是否替换全部匹配(默认 false)。',
                  'default': false,
                },
              },
              'required': ['old_text'],
            },
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
        final offsetLines = (args['offset_lines'] as num?)?.toInt() ?? 0;
        final maxLines = (args['max_lines'] as num?)?.toInt() ?? 500;
        final pattern = (args['pattern'] as String?)?.trim();
        if (offsetLines < 0) {
          throw ToolException('offset_lines must be >= 0');
        }
        if (maxLines < 1) {
          throw ToolException('max_lines must be >= 1');
        }
        final bytes = await file.read(path, maxBytes: maxBytes);
        try {
          final text = utf8.decode(bytes);
          return jsonEncode(
            _buildReadEnvelopeText(
              path: path,
              text: text,
              offsetLines: offsetLines,
              maxLines: maxLines,
              pattern: (pattern == null || pattern.isEmpty) ? null : pattern,
            ),
          );
        } on FormatException {
          // Binary file - skip the line-numbered envelope and
          // return the legacy shape so the model still gets
          // size + a clear "not text" marker.
          return jsonEncode({
            'action': 'read',
            'path': path,
            'size': bytes.length,
            'encoding': 'binary',
            'content': '[binary file, ${bytes.length} bytes]',
          });
        }

      case 'edit':
        final path = (args['path'] as String? ?? '').trim();
        if (path.isEmpty) {
          throw ToolException('"path" is required for edit');
        }
        final rawEdits = args['edits'];
        if (rawEdits is! List || rawEdits.isEmpty) {
          throw ToolException(
            '"edits" is required and must be a non-empty array',
          );
        }
        final ops = <EditOp>[];
        for (var i = 0; i < rawEdits.length; i++) {
          final entry = rawEdits[i];
          if (entry is! Map) {
            throw ToolException(
              'edits[$i] must be an object with old_text/new_text',
            );
          }
          try {
            ops.add(EditOp.fromJson(entry.cast<String, dynamic>()));
          } on FormatException catch (e) {
            throw ToolException('edits[$i]: ${e.message}');
          }
        }
        final result = await file.edit(path, ops);
        return jsonEncode(_editResultToJson(path: path, result: result));

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
        final offsetLines = (args['offset_lines'] as num?)?.toInt() ?? 0;
        final maxLines = (args['max_lines'] as num?)?.toInt() ?? 500;
        final pattern = (args['pattern'] as String?)?.trim();
        if (offsetLines < 0) {
          throw ToolException('offset_lines must be >= 0');
        }
        if (maxLines < 1) {
          throw ToolException('max_lines must be >= 1');
        }
        return _readDesktop(
          path,
          offsetLines: offsetLines,
          maxLines: maxLines,
          pattern: (pattern == null || pattern.isEmpty) ? null : pattern,
        );
      case 'read_attr':
        return _readAttrDesktop(path);
      case 'edit':
        final rawEdits = args['edits'];
        if (rawEdits is! List || rawEdits.isEmpty) {
          throw ToolException(
            '"edits" is required and must be a non-empty array',
          );
        }
        final ops = <EditOp>[];
        for (var i = 0; i < rawEdits.length; i++) {
          final entry = rawEdits[i];
          if (entry is! Map) {
            throw ToolException(
              'edits[$i] must be an object with old_text/new_text',
            );
          }
          try {
            ops.add(EditOp.fromJson(entry.cast<String, dynamic>()));
          } on FormatException catch (e) {
            throw ToolException('edits[$i]: ${e.message}');
          }
        }
        return _editDesktop(path, ops);
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
          'unknown action: $action (expected read/read_attr/edit/write/append/delete/rename/list_dir)',
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

  Future<String> _readDesktop(
    String path, {
    int offsetLines = 0,
    int maxLines = 500,
    String? pattern,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ToolException('file not found: $path');
    }
    try {
      final bytes = await file.readAsBytes();
      try {
        final text = utf8.decode(bytes);
        return jsonEncode(
          _buildReadEnvelopeText(
            path: path,
            text: text,
            offsetLines: offsetLines,
            maxLines: maxLines,
            pattern: pattern,
          ),
        );
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

  Future<String> _editDesktop(String path, List<EditOp> ops) async {
    final file = File(path);
    if (!await file.exists()) {
      // Soft error so the model can react (vs a hard
      // ToolException that breaks the agent loop).
      return jsonEncode(
        _editResultToJson(
          path: path,
          result: EditResult.error(
            code: 'PATH_NOT_FOUND',
            message: 'file not found: $path',
          ),
        ),
      );
    }
    try {
      final original = await file.readAsString();
      final sizeBefore = utf8.encode(original).length;
      // Validate every edit up front against the original
      // text - no partial writes, atomic batch.
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i];
        final occ = _countOccurrences(original, op.oldText);
        if (occ == 0) {
          return jsonEncode(
            _editResultToJson(
              path: path,
              result: EditResult.notFound(
                failedIndex: i,
                sizeBefore: sizeBefore,
                nearMatches: _findNearMatches(
                  source: original,
                  needle: op.oldText,
                  limit: 3,
                ),
              ),
            ),
          );
        }
        if (occ > 1 && !op.globalReplace) {
          return jsonEncode(
            _editResultToJson(
              path: path,
              result: EditResult.notUnique(
                failedIndex: i,
                sizeBefore: sizeBefore,
                foundCount: occ,
                candidates: _findCandidates(
                  source: original,
                  needle: op.oldText,
                  limit: 10,
                ),
              ),
            ),
          );
        }
      }
      // All validated - apply.
      var updated = original;
      for (final op in ops) {
        if (op.globalReplace) {
          updated = updated.replaceAll(op.oldText, op.newText);
        } else {
          final idx = updated.indexOf(op.oldText);
          updated = updated.replaceRange(
            idx,
            idx + op.oldText.length,
            op.newText,
          );
        }
      }
      await file.writeAsString(updated, flush: true);
      final sizeAfter = utf8.encode(updated).length;
      final diff = <EditDiffEntry>[];
      for (var i = 0; i < ops.length; i++) {
        final op = ops[i];
        diff.add(
          EditDiffEntry(
            editIndex: i,
            matchedLine: _lineNumberForOffset(original, op.oldText),
            oldPreview: _previewTextDesktop(op.oldText),
            newPreview: _previewTextDesktop(op.newText),
            replacements: op.globalReplace
                ? _countOccurrences(original, op.oldText)
                : 1,
          ),
        );
      }
      return jsonEncode(
        _editResultToJson(
          path: path,
          result: EditResult.success(
            applied: ops.length,
            sizeBefore: sizeBefore,
            sizeAfter: sizeAfter,
            diff: diff,
          ),
        ),
      );
    } catch (e) {
      throw ToolException('error editing file: $e');
    }
  }

  static int _countOccurrences(String source, String needle) {
    if (needle.isEmpty) return 0;
    var count = 0;
    var idx = 0;
    while (true) {
      final next = source.indexOf(needle, idx);
      if (next < 0) return count;
      count += 1;
      idx = next + needle.length;
    }
  }

  static int _lineNumberForOffset(String source, String needle) {
    final idx = source.indexOf(needle);
    if (idx <= 0) return 1;
    var line = 1;
    for (var i = 0; i < idx; i++) {
      if (source.codeUnitAt(i) == 0x0A) line += 1;
    }
    return line;
  }

  static List<EditNearMatch> _findNearMatches({
    required String source,
    required String needle,
    required int limit,
  }) {
    if (needle.isEmpty || source.isEmpty) return const [];
    // Pick a short, non-trivial probe to grep with. A probe
    // that's too long (e.g. the full first line of the
    // anchor) rarely matches anything; a probe that's too
    // short (e.g. 1-2 chars) is meaningless. We aim for the
    // first 8-char run of word characters from the start of
    // the anchor.
    final wordRun = RegExp(r'\S{4,}').firstMatch(needle);
    if (wordRun == null) return const [];
    var probe = wordRun.group(0)!;
    if (probe.length > 12) probe = probe.substring(0, 12);
    final lines = source.split('\n');
    final out = <EditNearMatch>[];
    for (var i = 0; i < lines.length && out.length < limit; i++) {
      if (lines[i].contains(probe)) {
        out.add(
          EditNearMatch(line: i + 1, preview: _previewTextDesktop(lines[i])),
        );
      }
    }
    return out;
  }

  static List<EditCandidate> _findCandidates({
    required String source,
    required String needle,
    required int limit,
  }) {
    if (needle.isEmpty) return const [];
    final out = <EditCandidate>[];
    final lines = source.split('\n');
    for (var i = 0; i < lines.length && out.length < limit; i++) {
      if (lines[i].contains(needle)) {
        out.add(
          EditCandidate(line: i + 1, preview: _previewTextDesktop(lines[i])),
        );
      }
    }
    return out;
  }

  static String _previewTextDesktop(String text) {
    var flat = text.replaceAll('\r\n', '\n').replaceAll('\n', '\\n');
    if (flat.length > 120) {
      flat = '${flat.substring(0, 120)}...';
    }
    return flat;
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

  // -------- Shared helpers (read envelope + edit result) --------

  /// Build the JSON envelope returned by the `read` action.
  ///
  /// Three modes, picked by which optional parameters the
  /// model passed:
  ///   * **pattern mode** — when [pattern] is non-null, return
  ///     every line that contains the pattern (case-sensitive
  ///     substring) plus two lines of context on each side,
  ///     each line prefixed with its 1-indexed line number
  ///     followed by `|`. The response carries `matches` (the
  ///     hit count) and `total_lines` so the model can decide
  ///     whether to widen the search.
  ///   * **page mode** — when [offsetLines] > 0 or [maxLines]
  ///     < total, return that slice. `truncated: true` plus a
  ///     `truncation_hint` tell the model how to continue.
  ///   * **default** — return the whole file, still line-
  ///     numbered (so the model can copy `old_text` anchors
  ///     verbatim into an `edit` call).
  static const int _readLineContextBefore = 2;
  static const int _readLineContextAfter = 2;

  Map<String, dynamic> _buildReadEnvelopeText({
    required String path,
    required String text,
    required int offsetLines,
    required int maxLines,
    String? pattern,
  }) {
    final allLines = text.split('\n');
    // Drop a trailing empty line that comes from a file ending
    // with `\n` - it's a phantom "line N+1" that confuses the
    // model. We keep the line numbering 1-indexed; if the
    // original file ended with `\n`, the real last line is
    // still accessible at index N-1.
    if (allLines.isNotEmpty && allLines.last.isEmpty && text.endsWith('\n')) {
      allLines.removeLast();
    }
    final totalLines = allLines.length;

    Map<String, dynamic> envelope;
    if (pattern != null) {
      envelope = _buildPatternEnvelope(
        path: path,
        allLines: allLines,
        totalLines: totalLines,
        pattern: pattern,
      );
    } else {
      envelope = _buildPageEnvelope(
        path: path,
        allLines: allLines,
        totalLines: totalLines,
        offsetLines: offsetLines,
        maxLines: maxLines,
      );
    }
    envelope['size'] = utf8.encode(text).length;
    envelope['encoding'] = 'utf-8';
    return envelope;
  }

  Map<String, dynamic> _buildPatternEnvelope({
    required String path,
    required List<String> allLines,
    required int totalLines,
    required String pattern,
  }) {
    // Build a set of line indices we want to emit, expanding
    // each hit by [readLineContextBefore] / [readLineContextAfter]
    // and clamping to the file. Using a sorted list of ranges
    // keeps the output in source order.
    final wanted = <int>{};
    for (var i = 0; i < allLines.length; i++) {
      if (allLines[i].contains(pattern)) {
        final lo = (i - _readLineContextBefore).clamp(0, allLines.length - 1);
        final hi = (i + _readLineContextAfter).clamp(0, allLines.length - 1);
        for (var k = lo; k <= hi; k++) {
          wanted.add(k);
        }
      }
    }
    // Cap at 200 line-emissions per read so a runaway pattern
    // can't dump the whole file.
    const maxEmitted = 200;
    final sorted = wanted.toList()..sort();
    final emitted = sorted.length > maxEmitted
        ? sorted.sublist(0, maxEmitted)
        : sorted;

    final buffer = StringBuffer();
    var lastEmitted = -2; // sentinel
    var isFirst = true;
    for (final idx in emitted) {
      if (idx != lastEmitted + 1 && lastEmitted >= 0) {
        if (!isFirst) buffer.write('\n');
        buffer.write('  ...');
        isFirst = false;
      }
      if (!isFirst) buffer.write('\n');
      buffer.write('${idx + 1}|${allLines[idx]}');
      isFirst = false;
      lastEmitted = idx;
    }

    final matches = allLines.where((l) => l.contains(pattern)).length;
    final truncated = emitted.length < sorted.length;
    final hint = truncated
        ? 'pattern matched $matches lines; returned ${emitted.length} '
              'lines of context. Narrow the pattern or read in pages with '
              'offset_lines / max_lines.'
        : 'pattern matched $matches lines; returned ${emitted.length} '
              'lines of context (each hit plus 2 lines before / after).';
    return {
      'action': 'read',
      'path': path,
      'mode': 'pattern',
      'pattern': pattern,
      'matches': matches,
      'total_lines': totalLines,
      'returned_lines': emitted.length,
      'truncated': truncated,
      'truncation_hint': hint,
      'content': buffer.toString(),
    };
  }

  Map<String, dynamic> _buildPageEnvelope({
    required String path,
    required List<String> allLines,
    required int totalLines,
    required int offsetLines,
    required int maxLines,
  }) {
    final startIdx = offsetLines.clamp(0, totalLines);
    final endIdx = (offsetLines + maxLines).clamp(0, totalLines);
    final slice = allLines.sublist(startIdx, endIdx);
    final buffer = StringBuffer();
    for (var i = 0; i < slice.length; i++) {
      final lineNo = startIdx + i + 1; // 1-indexed
      buffer.write('$lineNo|${slice[i]}');
      // Re-add the original `\n` separator so the model sees
      // a faithful representation of the file. (No `writeln` -
      // we want exact control over trailing whitespace.)
      if (i < slice.length - 1) buffer.write('\n');
    }
    final truncated = endIdx < totalLines || startIdx > 0;
    String? hint;
    if (truncated) {
      if (startIdx == 0) {
        hint =
            'file has $totalLines lines. Read 1-$endIdx. Continue with '
            'offset_lines=$endIdx max_lines=$maxLines, or set pattern="..." '
            'to grep for a specific symbol.';
      } else {
        hint =
            'file has $totalLines lines. Read ${startIdx + 1}-$endIdx. '
            'Continue with offset_lines=$endIdx max_lines=$maxLines, or use '
            'pattern="..." to grep.';
      }
    }
    final map = <String, dynamic>{
      'action': 'read',
      'path': path,
      'mode': truncated ? 'page' : 'full',
      'offset_lines': startIdx,
      'total_lines': totalLines,
      'returned_lines': slice.length,
      'start_line': startIdx + 1,
      'end_line': endIdx,
      'truncated': truncated,
      'content': buffer.toString(),
    };
    if (hint != null) map['truncation_hint'] = hint;
    return map;
  }

  /// Shape an [EditResult] into the JSON envelope the model
  /// sees. Keeps the response flat + small so the model can
  /// confirm "yes, that's the change" without re-reading the
  /// file.
  Map<String, dynamic> _editResultToJson({
    required String path,
    required EditResult result,
  }) {
    if (result.ok) {
      return {
        'action': 'edit',
        'path': path,
        'ok': true,
        'applied': result.applied,
        'size_before': result.sizeBefore,
        'size_after': result.sizeAfter,
        'diff': result.diff
            .map(
              (d) => {
                'edit_index': d.editIndex,
                'matched_line': d.matchedLine,
                'replacements': d.replacements,
                'old_preview': d.oldPreview,
                'new_preview': d.newPreview,
              },
            )
            .toList(),
      };
    }
    final base = {
      'action': 'edit',
      'path': path,
      'ok': false,
      'error_code': result.errorCode,
      'message': result.errorMessage,
      'failed_index': result.failedIndex,
    };
    if (result.nearMatches.isNotEmpty) {
      base['near_matches'] = result.nearMatches
          .map((m) => {'line': m.line, 'preview': m.preview})
          .toList();
    }
    if (result.candidates.isNotEmpty) {
      base['candidates'] = result.candidates
          .map((c) => {'line': c.line, 'preview': c.preview})
          .toList();
    }
    return base;
  }
}
