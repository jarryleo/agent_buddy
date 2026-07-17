import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// Pure-Dart, platform-agnostic regex search over a tree of files.
///
/// Used by the built-in `search` tool. The orchestrator (in
/// `lib/services/tools/search_tool.dart`) wires it to the right
/// file-reader — `dart:io` on desktop, `FileService` on mobile —
/// so the same algorithm runs everywhere.
///
/// **Performance plan** (the user's main concern):
///   1. **Cheap skip-list** by file extension and directory name.
///      We never read binary files (images / videos / archives /
///      lock files / minified blobs) and we never recurse into
///      heavy dependency caches (`.git`, `node_modules`,
///      `build`, `.dart_tool`, `Pods`, `target`, `dist`, …). This
///      is the single biggest win on a fresh clone of a large
///      project: those folders account for 90% of the bytes on
///      disk and we never touch them.
///   2. **Bounded-concurrency I/O** with a small worker pool.
///      We don't issue thousands of `readAsBytes` futures in
///      parallel — we keep at most [_readConcurrency] outstanding
///      reads. The pool adapts to the user's machine
///      (`Platform.numberOfProcessors`, capped at 16).
///   3. **Per-file size cap** (`maxFileSizeBytes`) so a single
///      500 MB log file can't stall the search.
///   4. **Early termination** at `maxResults` matches. The
///      moment we have enough, we cancel the in-flight pool and
///      return. On a 100k-file repo, this means a targeted
///      pattern finishes in milliseconds once any of the
///      candidate files report a hit.
class SearchService {
  SearchService();

  /// The folders we never recurse into, by name. Matched against
  /// the last segment of a path. Casing is normalized to lower.
  static const Set<String> _skipDirNames = <String>{
    // VCS
    '.git',
    '.hg',
    '.svn',
    '.bzr',
    // Dependency caches
    'node_modules',
    '.pnp',
    '.dart_tool',
    '.pub-cache',
    '.gradle',
    'Pods',
    '.symlinks',
    'vendor',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    '.tox',
    'venv',
    '.venv',
    'env',
    // Build outputs
    'build',
    'dist',
    'out',
    'target',
    'bin',
    'obj',
    '.next',
    '.nuxt',
    '.svelte-kit',
    '.angular',
    '.turbo',
    '.cache',
    '.parcel-cache',
    '.vercel',
    '.netlify',
    'coverage',
    '.nyc_output',
    // Flutter / Dart
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    'ephemeral',
    // IDE
    '.idea',
    '.vscode',
    // OS
    '.ds_store',
    'thumbs.db',
  };

  /// File extensions we treat as binary. Matched against the
  /// extension with a leading `.` (case-folded).
  static const Set<String> _binaryExts = <String>{
    // Images
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.tiff',
    '.tif', '.heic', '.heif', '.avif', '.psd', '.ai', '.eps', '.raw',
    // Video
    '.mp4', '.mov', '.avi', '.mkv', '.webm', '.wmv', '.flv', '.m4v',
    '.mpeg', '.mpg', '.3gp',
    // Audio
    '.mp3', '.wav', '.flac', '.ogg', '.oga', '.m4a', '.aac', '.opus',
    '.wma', '.aiff',
    // Archives
    '.zip', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.7z', '.rar', '.jar',
    '.war', '.ear', '.whl', '.apk', '.aab', '.ipa', '.dmg', '.iso',
    '.cab', '.deb', '.rpm',
    // Documents
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.rtf',
    '.odt', '.ods', '.odp', '.epub', '.mobi',
    // Executables / native code
    '.exe', '.dll', '.so', '.dylib', '.class', '.o', '.a', '.lib',
    '.pdb', '.obj', '.exp', '.pyc', '.pyo',
    // Fonts
    '.ttf', '.otf', '.woff', '.woff2', '.eot',
    // Lockfiles / minified
    '.lock', '.sum',
    '.min.js', '.min.css', '.min.map', '.map',
    // Databases / serialized
    '.sqlite', '.sqlite3', '.db', '.mdb', '.accdb', '.parquet', '.arrow',
    '.pbf', '.proto.bin',
  };

  /// Light upper bound on in-flight file reads. We don't want
  /// the futures queue to balloon on a 50k-file repo.
  static int get _readConcurrency {
    final cores = Platform.numberOfProcessors;
    if (cores <= 0) return 8;
    return cores.clamp(2, 16);
  }

  /// Run a search. [SearchArgs.rootAbs] must be an absolute
  /// on-disk path (the tool layer is responsible for resolving
  /// working directory / picker paths into one).
  Future<SearchResult> search(SearchArgs args) async {
    final regex = _compileRegex(
      args.pattern,
      caseSensitive: args.caseSensitive,
    );
    final globMatcher = _GlobMatcher(
      include: args.includeGlob,
      exclude: args.excludeGlob,
      caseSensitive: args.caseSensitive,
    );
    final root = args.rootAbs;
    final stat = await FileSystemEntity.type(root);
    if (stat == FileSystemEntityType.notFound) {
      throw SearchException('path not found: $root');
    }
    if (stat == FileSystemEntityType.directory &&
        _shouldSkipDir(p.basename(root))) {
      throw SearchException('refusing to search inside "${p.basename(root)}"');
    }

    // 1) Collect candidate files via a recursive walk.
    final candidates = <String>[];
    final walk = _WalkOutcome();
    if (stat == FileSystemEntityType.directory) {
      await _walk(
        root,
        onDir: (dir) => !_shouldSkipDir(p.basename(dir)),
        onFile: (file) {
          if (candidates.length >= args.maxFiles) {
            walk.hitFileCap = true;
            return false;
          }
          if (globMatcher.shouldSkipFile(file, root)) return true;
          candidates.add(file);
          return true;
        },
      );
    } else {
      // Single file passed as `path` - the user pointed at
      // it directly, so we always search it (the include
      // glob is for bulk filtering during a directory walk).
      candidates.add(root);
    }

    // 2) Merge in the explicit `files` list (deduped).
    if (args.files != null) {
      for (final f in args.files!) {
        if (f.isEmpty) continue;
        if (globMatcher.shouldSkipFile(f, root)) continue;
        if (!candidates.contains(f)) candidates.add(f);
      }
    }
    walk.candidateCount = candidates.length;

    // 3) Read + match with bounded concurrency.
    final stopwatch = Stopwatch()..start();
    final accumulator = _SearchAccumulator(
      maxResults: args.maxResults,
      contextLines: args.contextLines,
      previewChars: 240,
    );

    // Bounded-concurrency pool. We keep at most
    // [_readConcurrency] reads in flight at once. As soon as
    // a batch finishes (or we'd exceed the cap), we await
    // the batch and start the next one. The refilling
    // happens as soon as the slowest read in the current
    // batch returns, which is fine because disk reads are
    // already pipelined by the OS.
    final pool = <Future<void>>[];
    var i = 0;
    while (i < candidates.length && !accumulator.isSaturated) {
      while (pool.length < _readConcurrency &&
          i < candidates.length &&
          !accumulator.isSaturated) {
        final path = candidates[i++];
        pool.add(
          _readAndSearchOne(
            path: path,
            root: root,
            regex: regex,
            args: args,
            accumulator: accumulator,
          ),
        );
      }
      if (pool.isEmpty) break;
      // Future.wait (vs Future.any) keeps the logic simple
      // and the throughput is fine because the OS will
      // pipeline the underlying reads.
      final results = await Future.wait(pool);
      pool.clear();
      // Suppress lints; we don't propagate per-file errors
      // (they're folded into the accumulator envelope).
      for (final _ in results) {}
    }
    stopwatch.stop();

    final truncated =
        accumulator.totalMatches >= args.maxResults || walk.hitFileCap;

    accumulator.elapsedMs = stopwatch.elapsedMilliseconds;
    return accumulator.toResult(
      root: root,
      pattern: args.pattern,
      candidateFiles: walk.candidateCount,
      scannedFiles: i,
      scannedBytes: accumulator.scannedBytes,
      truncated: truncated,
    );
  }

  /// In-memory variant used by the mobile branch of the tool.
  /// The mobile FileService can't expose raw directory walks
  /// cheaply, so the tool pre-enumerates the file list (via
  /// listDir) and pre-reads each file (via read). This method
  /// then runs the same regex pipeline on the in-memory text.
  SearchResult searchInMemory({
    required SearchArgs args,
    required List<({String path, String content})> entries,
  }) {
    final regex = _compileRegex(
      args.pattern,
      caseSensitive: args.caseSensitive,
    );
    final globMatcher = _GlobMatcher(
      include: args.includeGlob,
      exclude: args.excludeGlob,
      caseSensitive: args.caseSensitive,
    );
    final accumulator = _SearchAccumulator(
      maxResults: args.maxResults,
      contextLines: args.contextLines,
      previewChars: 240,
    );
    final stopwatch = Stopwatch()..start();
    var scannedBytes = 0;
    for (final entry in entries) {
      if (accumulator.isSaturated) break;
      if (globMatcher.shouldSkipFile(entry.path, args.rootAbs)) continue;
      final bytes = utf8.encode(entry.content).length;
      scannedBytes += bytes;
      accumulator.addScannedBytes(bytes);
      _scanText(
        path: entry.path,
        root: args.rootAbs,
        text: entry.content,
        bytes: bytes,
        regex: regex,
        accumulator: accumulator,
      );
    }
    stopwatch.stop();
    accumulator.elapsedMs = stopwatch.elapsedMilliseconds;
    return accumulator.toResult(
      root: args.rootAbs,
      pattern: args.pattern,
      candidateFiles: entries.length,
      scannedFiles: entries.length,
      scannedBytes: scannedBytes,
      truncated: accumulator.totalMatches >= args.maxResults,
    );
  }

  // -------- internals --------

  Future<void> _readAndSearchOne({
    required String path,
    required String root,
    required RegExp regex,
    required SearchArgs args,
    required _SearchAccumulator accumulator,
  }) async {
    final relative = _relativeOrBasename(path, root);
    final file = File(path);
    if (!await file.exists()) {
      accumulator.addFileError(relativePath: relative, error: 'file not found');
      return;
    }
    final size = await file.length();
    if (size > args.maxFileSizeBytes) {
      accumulator.addFileError(
        relativePath: relative,
        error:
            'skipped (size ${_formatBytes(size)} > cap ${_formatBytes(args.maxFileSizeBytes)})',
      );
      return;
    }
    if (_isBinaryExtension(path)) {
      accumulator.addFileError(
        relativePath: relative,
        error: 'skipped (binary extension)',
      );
      return;
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException catch (e) {
      accumulator.addFileError(
        relativePath: relative,
        error: 'read failed: ${e.message}',
      );
      return;
    }
    accumulator.addScannedBytes(bytes.length);
    final text = utf8.decode(bytes, allowMalformed: true);
    _scanText(
      path: relative,
      root: root,
      text: text,
      bytes: bytes.length,
      regex: regex,
      accumulator: accumulator,
    );
  }

  void _scanText({
    required String path,
    required String root,
    required String text,
    required int bytes,
    required RegExp regex,
    required _SearchAccumulator accumulator,
  }) {
    final matches = regex.allMatches(text);
    if (matches.isEmpty) return;
    final lines = text.split('\n');
    for (final m in matches) {
      if (accumulator.isSaturated) break;
      final lc = _lineColumnFor(text, m.start);
      final lineText = (lc.line >= 1 && lc.line <= lines.length)
          ? lines[lc.line - 1]
          : '';
      accumulator.addMatch(
        path: path,
        root: root,
        line: lc.line,
        column: lc.column,
        matchStart: lc.column - 1,
        matchEnd: lc.column - 1 + (m.end - m.start),
        lineText: lineText,
        lines: lines,
      );
    }
  }

  /// Convert a global string offset to a 1-indexed (line, column)
  /// pair.
  ({int line, int column}) _lineColumnFor(String text, int offset) {
    var line = 1;
    var lastBreak = -1;
    final end = offset < text.length ? offset : text.length;
    for (var i = 0; i < end; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        line += 1;
        lastBreak = i;
      }
    }
    final column = offset - lastBreak;
    return (line: line, column: column);
  }

  RegExp _compileRegex(String pattern, {required bool caseSensitive}) {
    if (pattern.isEmpty) {
      throw const SearchException('pattern must not be empty');
    }
    try {
      return RegExp(pattern, caseSensitive: caseSensitive, multiLine: true);
    } on FormatException catch (e) {
      throw SearchException('invalid regex: ${e.message}');
    }
  }

  String _relativeOrBasename(String path, String root) {
    if (path == root) return p.basename(path);
    if (root.isEmpty) return p.basename(path);
    try {
      return p.relative(path, from: root);
    } on Exception {
      return p.basename(path);
    }
  }

  bool _shouldSkipDir(String name) {
    if (name.isEmpty) return false;
    return _skipDirNames.contains(name.toLowerCase());
  }

  bool _isBinaryExtension(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext.isEmpty) return false;
    return _binaryExts.contains(ext);
  }

  /// Walk [root] recursively. [onDir] decides whether to
  /// descend; [onFile] decides whether to record the file and
  /// whether to stop walking entirely. Stops as soon as either
  /// callback returns `false`.
  Future<void> _walk(
    String root, {
    required FutureOr<bool> Function(String dir) onDir,
    required FutureOr<bool> Function(String file) onFile,
  }) async {
    final queue = Queue<String>()..add(root);
    while (queue.isNotEmpty) {
      final dir = queue.removeFirst();
      if (!await onDir(dir)) continue;
      await for (final entity in Directory(
        dir,
      ).list(recursive: false, followLinks: false)) {
        if (entity is Directory) {
          queue.add(entity.path);
        } else if (entity is File) {
          final keep = await onFile(entity.path);
          if (!keep) return;
        }
        // Links + others are ignored.
      }
    }
  }

  String _formatBytes(int n) {
    if (n < 1024) return '${n}B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)}KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)}GB';
  }
}

/// What the tool wants to search. The tool layer is responsible
/// for resolving `path` / `files` into an absolute on-disk root
/// (or a list of explicit file paths) before calling
/// [SearchService.search].
class SearchArgs {
  const SearchArgs({
    required this.pattern,
    required this.rootAbs,
    this.files,
    this.includeGlob,
    this.excludeGlob,
    this.caseSensitive = false,
    this.maxResults = 200,
    this.maxFiles = 5000,
    this.maxFileSizeBytes = 5 * 1024 * 1024,
    this.contextLines = 0,
  });

  /// The regex to search for. ECMAScript syntax (Dart `RegExp`).
  /// Empty strings are rejected.
  final String pattern;

  /// Absolute on-disk root for the directory walk. Required.
  final String rootAbs;

  /// Optional explicit list of files to also search, on top of
  /// the directory walk. Paths may be absolute or relative to
  /// [rootAbs].
  final List<String>? files;

  /// Include glob (e.g. `*.dart`, `**/*.dart`). Only files
  /// whose path matches are searched. `null` = search every
  /// non-skipped file.
  final String? includeGlob;

  /// Comma-separated exclude globs (e.g. `*.test.dart,*.g.dart`).
  /// `null` = don't exclude.
  final String? excludeGlob;

  /// Whether the regex is case-sensitive. Defaults to `false`.
  final bool caseSensitive;

  /// Hard cap on the number of emitted matches. The search
  /// stops as soon as this many are collected. Defaults to 200.
  final int maxResults;

  /// Hard cap on the number of candidate files walked. Defaults
  /// to 5000 — even on a 100k-file repo, the walk bails after
  /// 5000 (cheaper than continuing to stream directory entries
  /// the user probably doesn't care about).
  final int maxFiles;

  /// Per-file byte cap. Files larger than this are skipped with
  /// a short error in the response. Defaults to 5 MB.
  final int maxFileSizeBytes;

  /// Lines of context to include before/after each match.
  /// Defaults to 0 (no context).
  final int contextLines;
}

/// Thrown by [SearchService.search] for input-level errors (bad
/// regex, missing path). Per-file read errors are folded into
/// the result envelope, not thrown.
class SearchException implements Exception {
  const SearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

class _WalkOutcome {
  int candidateCount = 0;
  bool hitFileCap = false;
}

class _SearchAccumulator {
  _SearchAccumulator({
    required this.maxResults,
    required this.contextLines,
    required this.previewChars,
  });
  final int maxResults;
  final int contextLines;
  final int previewChars;

  final Map<String, SearchFileGroup> _files = <String, SearchFileGroup>{};
  final Map<String, String> _fileErrors = <String, String>{};
  int scannedBytes = 0;
  int _totalMatches = 0;
  int elapsedMs = 0;

  int get totalMatches => _totalMatches;
  bool get isSaturated => _totalMatches >= maxResults;

  void addScannedBytes(int n) {
    scannedBytes += n;
  }

  void addFileError({required String relativePath, required String error}) {
    _fileErrors[relativePath] = error;
  }

  void addMatch({
    required String path,
    required String root,
    required int line,
    required int column,
    required int matchStart,
    required int matchEnd,
    required String lineText,
    required List<String> lines,
  }) {
    if (_totalMatches >= maxResults) return;
    _totalMatches += 1;
    final group = _files.putIfAbsent(path, () => SearchFileGroup(path: path));
    final preview = _truncateLine(lineText);
    final ctxBefore = contextLines > 0
        ? _contextFor(lines, line, -contextLines)
        : const <String>[];
    final ctxAfter = contextLines > 0
        ? _contextFor(lines, line, contextLines)
        : const <String>[];
    group.matches.add(
      SearchMatchEntry(
        line: line,
        column: column,
        matchStart: matchStart,
        matchEnd: matchEnd,
        text: preview,
        contextBefore: ctxBefore,
        contextAfter: ctxAfter,
      ),
    );
  }

  List<String> _contextFor(List<String> lines, int hitLine, int delta) {
    // delta > 0: lines after the hit. delta < 0: lines before.
    // Output is in source order so the model can read the
    // snippet top-to-bottom.
    final out = <String>[];
    if (delta > 0) {
      for (var k = 1; k <= delta; k++) {
        final idx = hitLine - 1 + k;
        if (idx >= lines.length) break;
        out.add(_truncateLine(lines[idx]));
      }
    } else {
      // Walk from the furthest-before line down to the
      // closest-before line so the output ends up in source
      // order (line N-2, line N-1, line N).
      for (var k = -delta; k >= 1; k--) {
        final idx = hitLine - 1 - k;
        if (idx < 0) break;
        out.add(_truncateLine(lines[idx]));
      }
    }
    return out;
  }

  String _truncateLine(String s) {
    if (s.length <= previewChars) return s;
    return '${s.substring(0, previewChars)}…';
  }

  SearchResult toResult({
    required String root,
    required String pattern,
    required int candidateFiles,
    required int scannedFiles,
    required int scannedBytes,
    required bool truncated,
  }) {
    final fileList = _files.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final errorList =
        _fileErrors.entries
            .map((e) => {'file': e.key, 'error': e.value})
            .toList()
          ..sort(
            (a, b) => (a['file'] as String).compareTo(b['file'] as String),
          );
    return SearchResult._(
      root: root,
      pattern: pattern,
      candidateFiles: candidateFiles,
      scannedFiles: scannedFiles,
      scannedBytes: scannedBytes,
      totalMatches: _totalMatches,
      elapsedMs: elapsedMs,
      truncated: truncated,
      files: fileList,
      fileErrors: errorList,
    );
  }
}

class SearchFileGroup {
  SearchFileGroup({required this.path});
  final String path;
  final List<SearchMatchEntry> matches = <SearchMatchEntry>[];
}

class SearchMatchEntry {
  const SearchMatchEntry({
    required this.line,
    required this.column,
    required this.matchStart,
    required this.matchEnd,
    required this.text,
    required this.contextBefore,
    required this.contextAfter,
  });
  final int line;
  final int column;
  final int matchStart;
  final int matchEnd;
  final String text;
  final List<String> contextBefore;
  final List<String> contextAfter;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'line': line,
      'column': column,
      'match_start': matchStart,
      'match_end': matchEnd,
      'text': text,
    };
    if (contextBefore.isNotEmpty) m['context_before'] = contextBefore;
    if (contextAfter.isNotEmpty) m['context_after'] = contextAfter;
    return m;
  }
}

/// The wire-format result of a search. Tools turn this into a
/// JSON envelope for the model.
class SearchResult {
  const SearchResult._({
    required this.root,
    required this.pattern,
    required this.candidateFiles,
    required this.scannedFiles,
    required this.scannedBytes,
    required this.totalMatches,
    required this.elapsedMs,
    required this.truncated,
    required this.files,
    required this.fileErrors,
  });

  /// Absolute on-disk root that was searched.
  final String root;

  /// The pattern the user asked for.
  final String pattern;

  /// How many candidate files the walk found.
  final int candidateFiles;

  /// How many candidate files were actually read + scanned.
  final int scannedFiles;

  /// Total bytes read (best-effort).
  final int scannedBytes;

  /// Number of match lines emitted (sum across files).
  final int totalMatches;

  /// Wall-clock time of the search.
  final int elapsedMs;

  /// True if we stopped early because we hit `maxResults` or
  /// `maxFiles`.
  final bool truncated;

  /// Per-file match groups, sorted by path.
  final List<SearchFileGroup> files;

  /// Per-file errors (read failed, size cap, etc.) the model
  /// can surface to the user.
  final List<Map<String, String>> fileErrors;

  /// Render to a compact JSON-shaped map for the model.
  Map<String, dynamic> toJson() {
    final fileList = files
        .map(
          (g) => {
            'file': g.path,
            'match_count': g.matches.length,
            'matches': g.matches.map((m) => m.toJson()).toList(),
          },
        )
        .toList();
    return {
      'query': pattern,
      'root': root,
      'scanned_files': scannedFiles,
      'candidate_files': candidateFiles,
      'scanned_bytes': scannedBytes,
      'total_matches': totalMatches,
      'elapsed_ms': elapsedMs,
      'truncated': truncated,
      'files': fileList,
      if (fileErrors.isNotEmpty) 'file_errors': fileErrors,
    };
  }
}

/// Minimal glob matcher supporting `*`, `**`, `?` and character
/// classes via regex conversion. Used for include/exclude globs.
class _GlobMatcher {
  _GlobMatcher({String? include, String? exclude, required bool caseSensitive})
    : _include = include == null || include.trim().isEmpty
          ? null
          : _compile(include, caseSensitive),
      _excludeRaw = exclude == null || exclude.trim().isEmpty
          ? const <RegExp>[]
          : exclude
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .map((s) => _compile(s, caseSensitive))
                .toList();

  final RegExp? _include;
  final List<RegExp> _excludeRaw;

  static RegExp _compile(String glob, bool caseSensitive) {
    final buf = StringBuffer(r'^');
    var i = 0;
    while (i < glob.length) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          // `**` matches anything including `/`. A trailing
          // `/` is consumed so `src/**` and `src/**/foo` both
          // work.
          buf.write('.*');
          i += 2;
          if (i < glob.length && glob[i] == '/') {
            i++;
          }
        } else {
          // Single `*` matches anything except `/`.
          buf.write('[^/]*');
          i++;
        }
      } else if (c == '?') {
        buf.write('[^/]');
        i++;
      } else if (c == '[') {
        final end = glob.indexOf(']', i + 1);
        if (end < 0) {
          buf.write(RegExp.escape('['));
          i++;
        } else {
          buf.write(glob.substring(i, end + 1));
          i = end + 1;
        }
      } else {
        buf.write(RegExp.escape(c));
        i++;
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString(), caseSensitive: caseSensitive);
  }

  /// Decide whether [absolutePath] should be skipped based on
  /// the include / exclude globs. [root] is the search root so
  /// the matcher sees relative paths when convenient.
  bool shouldSkipFile(String absolutePath, String root) {
    // Match against the *relative* path under root, falling
    // back to the basename. This makes `*.dart` and
    // `lib/*.dart` work as expected.
    String matchTarget;
    if (root.isNotEmpty && p.isWithin(root, absolutePath)) {
      matchTarget = p.relative(absolutePath, from: root);
    } else {
      matchTarget = p.basename(absolutePath);
    }
    // Normalize Windows backslashes so a single `**/*.dart`
    // works on Windows. The user's input uses `/` (the typical
    // glob separator); we want both `/` and `\` to match.
    matchTarget = matchTarget.replaceAll('\\', '/');
    final include = _include;
    if (include != null && !include.hasMatch(matchTarget)) {
      return true;
    }
    for (final ex in _excludeRaw) {
      if (ex.hasMatch(matchTarget)) return true;
    }
    return false;
  }
}
