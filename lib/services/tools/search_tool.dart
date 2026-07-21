import 'dart:convert';

import 'package:path/path.dart' as p;

import '../platform/file_service.dart';
import '../platform/file_service_impl.dart'
    show FileServiceError, FileServiceNotSupportedError;
import '../search_service.dart';
import '../tool_service.dart';
import 'tool_base.dart';

/// Built-in `search` tool — regex search across a directory tree
/// or a list of files.
///
/// **What it does for the model** — instead of asking the model
/// to `file read` files one by one (expensive in tokens) to
/// locate a symbol, the model passes a regex once and gets
/// back a compact `{file, line, column, text}` list of every
/// match. Designed to be fast even on large repos:
///
///   * default skip-list of heavy directories (`.git`,
///     `node_modules`, `build`, `Pods`, `target`, `dist`, …)
///     and binary file extensions (images, video, archives,
///     minified blobs, native code) so the first thing the
///     search does is *not* open a 4 GB `node_modules` folder.
///   * bounded-concurrency I/O with a small worker pool that
///     adapts to the host CPU count.
///   * hard caps (`max_results` / `max_files` /
///     `max_file_size_mb`) so a runaway pattern can't burn the
///     whole conversation budget on a single call.
///   * early termination: the search stops as soon as
///     `max_results` matches are collected, or the walk hits
///     `max_files`.
///
/// **Platforms**
///   * Desktop (Windows / macOS / Linux) — full path access.
///     `path` may be absolute or relative to the
///     user-selected model working directory. `path=""` means
///     "search the working directory".
///   * Mobile (Android / iOS) — same `picker://<id>` /
///     `working://<rel>` (or bare relative) path scheme as the
///     `file` tool. The model never sees the underlying OS
///     path; the bridge reads each file via `FileService`.
///   * Web — not supported (no working directory concept);
///     the schema returns `{}` and `isSupportedOnCurrentPlatform`
///     is `false`.
class SearchTool extends ToolBase {
  @override
  String get id => 'search';

  @override
  String get name => '搜索文件内容';

  @override
  String get description {
    if (isMobileForRuntime()) {
      return '用正则搜索文件内容,返回匹配的文件路径+行号+原文。比一个个 file read 省 token。'
          '手机端:path 用 working://<相对路径>(或裸相对路径)指工作目录里的位置,'
          '或用 picker://<id> 指单文件;files[] 直接列要搜的文件(混合两种 scheme 也行)。'
          '首次调用会先在用户选的工作目录/picker 文件里搜,其他位置搜不到。'
          '默认自动跳过 .git/node_modules/build/Pods/二进制文件 等重文件夹,大仓库也能秒出。';
    }
    return '用正则搜索文件内容,返回匹配的文件路径+行号+原文。比一个个 file read 省 token。'
        'path 为空则搜用户选的工作目录,可填绝对路径或相对路径;'
        'files[] 直接列要搜的文件,会覆盖 path 行为。'
        '默认自动跳过 .git/node_modules/build/Pods/二进制文件 等重文件夹,大仓库也能秒出。';
  }

  @override
  String get shortDescription => '按正则搜目录/文件,返回匹配 (file,line,col,text)';

  @override
  bool get isSupportedOnCurrentPlatform =>
      isDesktopForRuntime() || isMobileForRuntime();

  @override
  String get compactSchemaForModel => '''
参数:
- pattern (string, 必填): ECMAScript 正则(不需要 // 包裹;^ 行首 \$ 行尾)
- path (string, 可选): 起始目录;desktop 可绝对/相对;mobile 用 working:// 或 picker://;空=工作目录
- files (string[], 可选): 直接列文件路径,会覆盖 path
- case_sensitive (bool, 默认 false)
- include_globs (string[], 可选): 例 "*.dart" / "**/*.dart" / "src/**" 限定类型
- exclude_globs (string[], 可选): 例 "*.g.dart,*.freezed.dart"
- max_results (int, 默认 200): 命中上限,达上限立即停
- max_files (int, 默认 5000): 扫描文件数上限
- max_file_size_mb (int, 默认 8): 单文件跳过阈值

返回: {matches:[{file,line,column,text}], total, scanned_files, skipped_files, truncated}

约束:
- 自动跳过 .git / node_modules / build / .dart_tool / Pods / target / dist / .idea / .vscode / __pycache__ / .next / .nuxt 等重目录,以及图片/视频/压缩包/可执行/.lock/.map 等二进制 —— 不用你排除,大仓库默认就快。
- mobile 端 picker:// 单文件直接走 FileService,无工作目录时报错。

最佳实践:
- **首选用法**:搜符号/字符串/函数名,`search(pattern:"ToolException", include_globs:["*.dart"])` 一秒扫整个 lib/,比逐个 file read 省 token 太多。
- 三道保护(max_results/max_files/max_file_size_mb):跑了半天还没结果就降低 max_files 或加 include_globs 收紧范围。
- 命中行带 1-based 行号 + 列号 + 原文,**直接拿 line 字段当 file.read 的 offset_lines,或当 file.edit 的 start_line/end_line**(配合 file.read 的 "N|" 行号前缀,避免整段文本匹配)。
''';

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    final desc = description;
    return {
      'type': 'function',
      'function': {
        'name': 'search',
        'description': desc,
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': isMobileForRuntime()
                  ? '要搜索的位置。working://<相对路径>(或裸相对路径)指工作目录里的子目录;'
                        'picker://<id> 指单文件;留空 + files[] 也行。'
                  : '要搜索的目录或文件路径。绝对路径或相对于用户工作目录的相对路径;留空则搜工作目录。',
            },
            'files': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  '直接列要搜的文件路径(覆盖 path 行为)。手机端支持 picker:// 和 working:// 混传。',
            },
            'pattern': {
              'type': 'string',
              'description':
                  '正则表达式(ECMAScript 语法,Dart RegExp)。默认不区分大小写,多行模式自动开启(^ 行首 \$ 行尾)。',
            },
            'include_glob': {
              'type': 'string',
              'description':
                  '文件过滤 glob(基于相对路径),如 "*.dart" / "**/*.dart" / "src/**"。支持 *、**、?、字符类。',
            },
            'exclude_glob': {
              'type': 'string',
              'description':
                  '排除的 glob 列表(逗号分隔),如 "*.test.dart,*.g.dart,*.freezed.dart"。',
            },
            'case_sensitive': {
              'type': 'boolean',
              'description': '是否大小写敏感(默认 false)',
              'default': false,
            },
            'max_results': {
              'type': 'integer',
              'description': '最多返回多少个匹配。命中后立即停止,默认 200。',
              'default': 200,
              'minimum': 1,
              'maximum': 5000,
            },
            'max_files': {
              'type': 'integer',
              'description': '最多扫多少个文件,默认 5000(防止在超大型项目里耗时太久)。',
              'default': 5000,
              'minimum': 1,
              'maximum': 100000,
            },
            'max_file_size_mb': {
              'type': 'integer',
              'description': '单个文件超过这个字节数就跳过(默认 5MB)。',
              'default': 5,
              'minimum': 1,
              'maximum': 200,
            },
            'context_lines': {
              'type': 'integer',
              'description': '每个匹配前后显示多少行上下文(默认 0,只看匹配行)。',
              'default': 0,
              'minimum': 0,
              'maximum': 20,
            },
          },
          'required': ['pattern'],
        },
      },
    };
  }

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

  // -------- Desktop --------

  Future<String> _executeDesktop(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final parsed = _parseArgs(args, services.workingDirectory);
    final service = SearchService();
    try {
      final result = await service.search(parsed.args);
      return _resultToJson(result, parsed.rootLabel);
    } on SearchException catch (e) {
      throw ToolException(e.message);
    }
  }

  // -------- Mobile --------

  Future<String> _executeMobile(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final parsed = _parseArgs(args, services.workingDirectory);
    final file = services.file;
    final entries = <({String path, String content})>[];

    // 1) Enumerate the candidate files via the FileService
    //    bridge. We can't use `dart:io` on mobile — the OS
    //    sandbox only exposes what the user explicitly picked.
    final working = file.workingDirectory;
    if (parsed.rootAbs != null) {
      // `path` was provided. We need to know whether it's a
      // single file or a directory.
      final root = parsed.rootAbs!;
      if (isPickerPath(root)) {
        // Single picker file. Read directly.
        final bytes = await file.read(
          root,
          maxBytes: parsed.args.maxFileSizeBytes,
        );
        final text = utf8.decode(bytes, allowMalformed: true);
        entries.add((path: root, content: text));
      } else {
        // working:// path or bare relative — list recursively.
        // If no working dir is configured, fall back to a
        // soft hint so the model can recover (telling the
        // user to pick a folder via the chat toolbar) instead
        // of failing the whole turn.
        if (working == null) {
          return _emptyMobileEnvelope(
            parsed: parsed,
            hint:
                'no working directory configured on mobile; '
                'pick a folder via the chat toolbar, or use '
                'files=[...] with picker:// ids',
          );
        }
        // If the user passed a relative path that resolves to
        // a single file (not a directory), listDir may return
        // an error; we catch and try a direct read.
        try {
          final listed = await file.listDir(root, recursive: true);
          final files = listed.where((e) => !e.isDirectory).toList();
          for (final f in files) {
            if (entries.length >= parsed.args.maxFiles) break;
            // FileService.listDir caps at 200 entries by
            // default; if it hit the cap, surface a hint to
            // the model so it can narrow the search.
            try {
              final bytes = await file.read(
                f.path,
                maxBytes: parsed.args.maxFileSizeBytes,
              );
              entries.add((
                path: f.path,
                content: utf8.decode(bytes, allowMalformed: true),
              ));
            } on FileServiceError catch (e) {
              // Surface per-file errors as a single accumulator
              // entry so the model sees them; we don't fail the
              // whole search because one file is unreadable.
              entries.add((
                path: f.path,
                content: '[unreadable: ${e.message}]',
              ));
            }
          }
        } on FileServiceError {
          // listDir rejected the path — maybe it points at a
          // single file, not a directory. Try a direct read.
          try {
            final bytes = await file.read(
              root,
              maxBytes: parsed.args.maxFileSizeBytes,
            );
            entries.add((
              path: root,
              content: utf8.decode(bytes, allowMalformed: true),
            ));
          } on FileServiceError catch (e2) {
            throw ToolException('cannot read "$root": ${e2.message}');
          }
          // (Otherwise rethrow the original listDir error.)
          // Note: the unhandled-by-us case is "path exists but
          // isn't a directory"; we already recovered by reading
          // it as a file. Other errors bubble up via the outer
          // throw above.
        }
      }
    }

    // 2) Merge in any explicit `files` list.
    if (parsed.args.files != null) {
      for (final path in parsed.args.files!) {
        if (path.isEmpty) continue;
        if (entries.any((e) => e.path == path)) continue;
        if (entries.length >= parsed.args.maxFiles) break;
        try {
          final bytes = await file.read(
            path,
            maxBytes: parsed.args.maxFileSizeBytes,
          );
          entries.add((
            path: path,
            content: utf8.decode(bytes, allowMalformed: true),
          ));
        } on FileServiceNotSupportedError {
          throw ToolException(
            'search is not supported on this platform; '
            'the file service is unavailable',
          );
        } on FileServiceError catch (e) {
          entries.add((path: path, content: '[unreadable: ${e.message}]'));
        }
      }
    }

    if (entries.isEmpty) {
      // No candidates. The model asked for a search but we
      // have nothing to scan — surface a soft signal so it
      // can pivot (e.g. "you forgot to pick a folder, or no
      // files matched the include glob").
      return jsonEncode({
        'action': 'search',
        'query': parsed.args.pattern,
        'root': parsed.rootLabel,
        'candidates': 0,
        'total_matches': 0,
        'truncated': false,
        'files': <Map<String, dynamic>>[],
        'hint': _mobileEmptyHint(working),
      });
    }

    final service = SearchService();
    final rootForResult = parsed.rootAbs ?? working ?? '<mobile-sandbox>';
    final result = service.searchInMemory(
      args: SearchArgs(
        pattern: parsed.args.pattern,
        rootAbs: rootForResult,
        includeGlob: parsed.args.includeGlob,
        excludeGlob: parsed.args.excludeGlob,
        caseSensitive: parsed.args.caseSensitive,
        maxResults: parsed.args.maxResults,
        maxFiles: parsed.args.maxFiles,
        maxFileSizeBytes: parsed.args.maxFileSizeBytes,
        contextLines: parsed.args.contextLines,
      ),
      entries: entries,
    );
    return _resultToJson(result, parsed.rootLabel);
  }

  String _mobileEmptyHint(String? working) {
    if (working == null) {
      return 'no working directory configured on mobile; '
          'pick a folder via the chat toolbar, or use files=[...] with picker:// ids';
    }
    return 'no candidate files found in the working directory; '
        'loosen include_glob or check that the path is correct';
  }

  /// Build the soft-failure envelope the tool returns when
  /// the mobile branch has nothing to search (no working dir,
  /// empty result, etc.). Matches the schema the happy path
  /// uses so the model can read the response uniformly.
  String _emptyMobileEnvelope({
    required _ParsedArgs parsed,
    required String hint,
  }) {
    return jsonEncode({
      'query': parsed.args.pattern,
      'root': parsed.rootLabel ?? '<mobile-sandbox>',
      'candidates': 0,
      'scanned_files': 0,
      'scanned_bytes': 0,
      'total_matches': 0,
      'elapsed_ms': 0,
      'truncated': false,
      'files': <Map<String, dynamic>>[],
      'hint': hint,
    });
  }

  // -------- Shared helpers --------

  /// Validated, normalized search args. [defaultWorkingDir] is
  /// the user's `modelWorkingDirectory` from storage (used as
  /// the implicit root when `path` is empty on desktop, and as
  /// the resolver for bare relative paths).
  _ParsedArgs _parseArgs(Map<String, dynamic> raw, String? defaultWorkingDir) {
    final pattern = (raw['pattern'] as String? ?? '').trim();
    if (pattern.isEmpty) {
      throw ToolException('"pattern" is required and must be non-empty');
    }
    final rawPath = (raw['path'] as String?)?.trim();
    final filesRaw = raw['files'];
    final files = (filesRaw is List)
        ? filesRaw
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList()
        : null;
    final hasPath = rawPath != null && rawPath.isNotEmpty;
    final hasFiles = files != null && files.isNotEmpty;
    if (!hasPath && !hasFiles) {
      // No explicit target. On desktop, default to the
      // configured working directory so the model can just
      // say "search for X" and get the whole project. On
      // mobile the model must be explicit because there is no
      // implicit "the project" — the only files the model
      // can see are user-picked ones.
      if (isMobileForRuntime()) {
        throw ToolException(
          'either "path" or "files" is required on mobile '
          '(no default working directory to fall back to)',
        );
      }
      if (defaultWorkingDir == null || defaultWorkingDir.isEmpty) {
        throw ToolException(
          'no working directory is configured and "path" was not given; '
          'set a model working directory in Settings, or pass "path" / "files"',
        );
      }
      // Fall through; we'll use the working dir as the root.
    }
    final includeGlob = (raw['include_glob'] as String?)?.trim();
    final excludeGlob = (raw['exclude_glob'] as String?)?.trim();
    final caseSensitive = raw['case_sensitive'] as bool? ?? false;
    final maxResults = (raw['max_results'] as num?)?.toInt() ?? 200;
    final maxFiles = (raw['max_files'] as num?)?.toInt() ?? 5000;
    final maxFileSizeMb = (raw['max_file_size_mb'] as num?)?.toInt() ?? 5;
    final contextLines = (raw['context_lines'] as num?)?.toInt() ?? 0;
    if (maxResults < 1 || maxResults > 5000) {
      throw ToolException('max_results must be in [1, 5000]');
    }
    if (maxFiles < 1 || maxFiles > 100000) {
      throw ToolException('max_files must be in [1, 100000]');
    }
    if (maxFileSizeMb < 1 || maxFileSizeMb > 200) {
      throw ToolException('max_file_size_mb must be in [1, 200]');
    }
    if (contextLines < 0 || contextLines > 20) {
      throw ToolException('context_lines must be in [0, 20]');
    }

    // Resolve the path on desktop: absolute / relative /
    // working-dir / fallback-to-working-dir when both path
    // and files are empty.
    String? rootAbs;
    String? label;
    if (hasPath) {
      if (isMobileForRuntime()) {
        // On mobile, FileService handles the resolution. We
        // hand the raw path through unchanged.
        rootAbs = rawPath;
        label = rawPath;
      } else {
        rootAbs = _resolveDesktopPath(rawPath, defaultWorkingDir);
        label = rootAbs;
      }
    } else if (!isMobileForRuntime() &&
        defaultWorkingDir != null &&
        defaultWorkingDir.isNotEmpty) {
      // No path and no files: default to the whole working
      // directory. The early-return above already raised
      // when this fallback wasn't available.
      rootAbs = defaultWorkingDir;
      label = defaultWorkingDir;
    }

    return _ParsedArgs(
      args: SearchArgs(
        pattern: pattern,
        rootAbs: rootAbs ?? defaultWorkingDir ?? p.current,
        files: files,
        includeGlob: includeGlob,
        excludeGlob: excludeGlob,
        caseSensitive: caseSensitive,
        maxResults: maxResults,
        maxFiles: maxFiles,
        maxFileSizeBytes: maxFileSizeMb * 1024 * 1024,
        contextLines: contextLines,
      ),
      rootAbs: rootAbs,
      rootLabel: label,
      includeGlob: includeGlob,
      excludeGlob: excludeGlob,
      caseSensitive: caseSensitive,
      maxResults: maxResults,
      maxFiles: maxFiles,
      maxFileSizeBytes: maxFileSizeMb * 1024 * 1024,
      contextLines: contextLines,
    );
  }

  String _resolveDesktopPath(String input, String? workingDir) {
    if (p.isAbsolute(input)) return p.normalize(input);
    if (workingDir == null || workingDir.isEmpty) {
      return p.normalize(p.absolute(input));
    }
    return p.normalize(p.join(workingDir, input));
  }

  /// Shape the [SearchResult] into a JSON envelope. [label] is
  /// the human-readable root the tool advertised in its args
  /// (so the model sees "the same path I asked for", not the
  /// internal absolute path). When [label] is `null` we fall
  /// back to the search's own root.
  String _resultToJson(SearchResult result, String? label) {
    final json = result.toJson();
    if (label != null) json['root'] = label;
    // Add a hint when the result was truncated so the model
    // knows to either narrow the pattern / glob or bump the
    // caps. Most calls don't hit this.
    if (result.truncated) {
      final reasons = <String>[];
      if (result.totalMatches >= 200) {
        reasons.add(
          'hit max_results cap; narrow the pattern or raise max_results',
        );
      }
      reasons.add(
        'hit max_files cap during walk; narrow include_glob or raise max_files',
      );
      json['truncation_hint'] = reasons.join('; ');
    }
    return jsonEncode(json);
  }
}

class _ParsedArgs {
  _ParsedArgs({
    required this.args,
    required this.rootAbs,
    required this.rootLabel,
    required this.includeGlob,
    required this.excludeGlob,
    required this.caseSensitive,
    required this.maxResults,
    required this.maxFiles,
    required this.maxFileSizeBytes,
    required this.contextLines,
  });
  final SearchArgs args;
  final String? rootAbs;
  final String? rootLabel;
  final String? includeGlob;
  final String? excludeGlob;
  final bool caseSensitive;
  final int maxResults;
  final int maxFiles;
  final int maxFileSizeBytes;
  final int contextLines;
}
