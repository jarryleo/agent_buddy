import 'dart:convert';

import '../../models/picked_file.dart';

/// Abstract surface for the platform file service. On Android /
/// iOS the implementation talks to the native bridge for SAF /
/// `UIDocumentPickerViewController` ops and uses the
/// user-selected working directory for `dart:io` access; on web
/// / non-supported platforms the stub returns `UnsupportedError`
/// for every op.
///
/// Path schemes the model is allowed to pass:
///   * `picker://<id>`       - a file the user picked via [pick]
///     (no Android / iOS runtime permission needed - SAF /
///     `UIDocumentPickerViewController` handle per-URI grants
///     themselves).
///   * `working://<rel>`     - a relative path under the
///     user-selected working directory (see [workingDirectory])
///   * `<rel>` (bare relative path, no scheme) - same as
///     `working://<rel>`; the FileService resolves it against
///     [workingDirectory].
///
/// Anything else (raw absolute path on mobile, `file://`,
/// `content://`) is rejected with an error - the model should
/// never see the underlying OS path. The schema enforces this;
/// the service double-checks.
///
/// The model defaults to operating on the user-selected working
/// directory (relative paths / `working://`) or on files the
/// user explicitly picked (`picker://<id>`). There are no other
/// sandbox roots - the previous `app://` scheme has been removed
/// in favor of a single, user-authorized working directory.
abstract class FileService {
  /// Open the system file picker. **Blocks until the user picks,
  /// cancels, or the OS dismisses the picker.** This is the
  /// intentional "wait for permission / user action" semantics:
  /// the tool execution is parked in the native bridge, the user
  /// makes their choice, then the future resolves. Never returns
  /// a transient error before the user has had a chance to answer.
  ///
  /// Returns `null` when the user explicitly cancelled (the
  /// model should treat this as a soft signal, not a failure).
  Future<PickedFile?> pick({String? mimeType, bool readOnly = false});

  /// Drop a previously-picked file from the in-memory map. Idempotent.
  Future<void> release(String id);

  /// Read raw bytes. Enforces [maxBytes] so a runaway model
  /// can't pull a 1 GB log file into the chat.
  Future<List<int>> read(String path, {int maxBytes = 2 * 1024 * 1024});

  /// Write (or append) raw bytes. `append=true` is rejected on
  /// `picker://<id>` paths (the OS picker doesn't expose an
  /// append mode to third-party apps - use [read] + [write]
  /// round-trip instead).
  Future<void> write(String path, List<int> bytes, {bool append = false});

  /// Delete a file or directory. Rejects `picker://<id>` paths
  /// - the picker grants per-URI access for read/write, not
  /// arbitrary delete on the user's filesystem. Use [release]
  /// to drop the local handle instead.
  Future<void> delete(String path, {bool recursive = false});

  /// Rename / move. Rejects `picker://<id>` paths for the same
  /// reason as [delete] - we can't move a file inside someone
  /// else's directory tree.
  Future<void> rename(String from, String to);

  /// List a directory. Only valid against `working://...` paths
  /// (a `picker://<id>` file has no browsable parent). Returns
  /// at most 200 entries (matches the desktop `FileTool._listDir`
  /// cap).
  Future<List<FileEntry>> listDir(String path, {bool recursive = false});

  /// Read attributes. Valid against `picker://` and
  /// `working://` paths.
  Future<FileAttrs> readAttr(String path);

  /// Apply a batch of line-based edits to the file at [path].
  /// The range is 1-based and inclusive. `end_line` may be omitted
  /// to edit only `start_line`; empty content deletes the range.
  ///
  /// Every range is validated before writing. The file is only
  /// written if all edits are valid. Batch edits are applied from
  /// the largest start line to the smallest start line so inserted
  /// or deleted lines do not invalidate later ranges.
  Future<EditResult> edit(String path, List<EditOp> edits);

  /// The user-selected working directory (an absolute path on
  /// the device filesystem). `null` when the user hasn't picked
  /// one - in which case the file tool rejects `working://`
  /// and bare-relative paths with a friendly error.
  ///
  /// This is a lazy lookup: each call reads the latest value
  /// from the `ToolService`'s `StorageService.modelWorkingDirectory`
  /// so the FileService never holds a stale snapshot.
  String? get workingDirectory;

  /// **Android only.** Open the system folder picker to
  /// (re-)select the working-directory tree. **Blocks until
  /// the user picks, cancels, or the OS dismisses the
  /// picker.** Mirrors [pick]'s "wait for user action" UX.
  ///
  /// Returns the newly-picked `(path, treeUri)` pair, or
  /// `null` when the user explicitly cancelled. On
  /// non-Android platforms this throws
  /// [FileServiceNotSupportedError] (iOS uses the app sandbox
  /// and doesn't need a tree picker; desktop already exposes
  /// arbitrary paths to the model).
  Future<({String path, String treeUri})?> pickWorkingDirectory();
}

/// Test / web factory signature. Defaults to a fresh
/// [FileService] on mobile, a stub elsewhere.
typedef FileServiceBuilder = FileService Function();

/// True when [input] is a `picker://<id>` reference. The bridge
/// keeps the id -> native-URI map in-process; the model only ever
/// sees this opaque scheme.
bool isPickerPath(String input) {
  if (input.length < 10) return false; // `picker://x` minimum
  if (!input.startsWith('picker://')) return false;
  final rest = input.substring('picker://'.length);
  if (rest.isEmpty || rest.contains('/') || rest.contains('\n')) {
    return false;
  }
  return true;
}

/// Extracts the `<id>` from a `picker://<id>` string. Returns
/// `null` if the input isn't a picker path.
String? pickerIdOf(String input) {
  if (!isPickerPath(input)) return null;
  return input.substring('picker://'.length);
}

/// True when [input] carries the `working://` scheme. Bare
/// relative paths (no scheme) that the tool wants resolved
/// against the user-selected working directory are *not*
/// flagged here - only the explicit `working://` prefix.
bool isWorkingPath(String input) {
  return input.startsWith('working://');
}

class EditOp {
  const EditOp({required this.startLine, this.endLine, required this.content});

  final int startLine;
  final int? endLine;
  final String content;

  int get resolvedEndLine => endLine ?? startLine;

  factory EditOp.fromJson(Map<String, dynamic> json) {
    final start = json['start_line'];
    if (start is! int) {
      throw const FormatException(
        'edit: start_line is required and must be an integer',
      );
    }
    if (start < 1) {
      throw const FormatException('edit: start_line must be >= 1');
    }
    final end = json['end_line'];
    if (end != null && end is! int) {
      throw const FormatException('edit: end_line must be an integer');
    }
    if (end != null && end < start) {
      throw const FormatException(
        'edit: end_line must be greater than or equal to start_line',
      );
    }
    final content = json['content'];
    if (content is! String) {
      throw const FormatException(
        'edit: content is required and must be a string',
      );
    }
    return EditOp(startLine: start, endLine: end as int?, content: content);
  }

  Map<String, dynamic> toJson() => {
    'start_line': startLine,
    if (endLine != null) 'end_line': endLine,
    'content': content,
  };
}

class EditResult {
  const EditResult._({
    required this.ok,
    required this.applied,
    this.failedIndex,
    this.errorCode,
    this.errorMessage,
    this.startLine,
    this.endLine,
    this.sizeBefore,
    this.sizeAfter,
    this.diff = const [],
  });

  factory EditResult.success({
    required int applied,
    required int sizeBefore,
    required int sizeAfter,
    required List<EditDiffEntry> diff,
  }) {
    return EditResult._(
      ok: true,
      applied: applied,
      sizeBefore: sizeBefore,
      sizeAfter: sizeAfter,
      diff: diff,
    );
  }

  factory EditResult.error({
    required String code,
    required String message,
    int? failedIndex,
    int? startLine,
    int? endLine,
    int? sizeBefore,
    int? sizeAfter,
  }) {
    return EditResult._(
      ok: false,
      applied: 0,
      failedIndex: failedIndex,
      errorCode: code,
      errorMessage: message,
      startLine: startLine,
      endLine: endLine,
      sizeBefore: sizeBefore,
      sizeAfter: sizeAfter,
    );
  }

  final bool ok;
  final int applied;
  final int? failedIndex;
  final String? errorCode;
  final String? errorMessage;
  final int? startLine;
  final int? endLine;
  final int? sizeBefore;
  final int? sizeAfter;
  final List<EditDiffEntry> diff;
}

class EditDiffEntry {
  const EditDiffEntry({
    required this.editIndex,
    required this.startLine,
    required this.endLine,
    required this.oldPreview,
    required this.newPreview,
    required this.replacements,
  });

  final int editIndex;
  final int startLine;
  final int endLine;
  final String oldPreview;
  final String newPreview;
  final int replacements;

  int get matchedLine => startLine;
}

enum TextFileEncoding { utf8, utf8Bom, utf16Le, utf16Be }

class TextFileData {
  const TextFileData({required this.text, required this.encoding});

  final String text;
  final TextFileEncoding encoding;

  static TextFileData decode(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return TextFileData(
        text: utf8.decode(bytes.sublist(3)),
        encoding: TextFileEncoding.utf8Bom,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      return TextFileData(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: true),
        encoding: TextFileEncoding.utf16Le,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      return TextFileData(
        text: _decodeUtf16(bytes.sublist(2), littleEndian: false),
        encoding: TextFileEncoding.utf16Be,
      );
    }
    return TextFileData(
      text: utf8.decode(bytes),
      encoding: TextFileEncoding.utf8,
    );
  }

  List<int> encode() {
    switch (encoding) {
      case TextFileEncoding.utf8:
        return utf8.encode(text);
      case TextFileEncoding.utf8Bom:
        return [0xef, 0xbb, 0xbf, ...utf8.encode(text)];
      case TextFileEncoding.utf16Le:
        return [0xff, 0xfe, ..._encodeUtf16(text, littleEndian: true)];
      case TextFileEncoding.utf16Be:
        return [0xfe, 0xff, ..._encodeUtf16(text, littleEndian: false)];
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    if (bytes.length.isOdd) {
      throw const FormatException('unsupported UTF-16 byte sequence');
    }
    final units = <int>[];
    for (var i = 0; i < bytes.length; i += 2) {
      units.add(
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(units);
  }

  static List<int> _encodeUtf16(String text, {required bool littleEndian}) {
    final bytes = <int>[];
    for (final unit in text.codeUnits) {
      if (littleEndian) {
        bytes.add(unit & 0xff);
        bytes.add(unit >> 8);
      } else {
        bytes.add(unit >> 8);
        bytes.add(unit & 0xff);
      }
    }
    return bytes;
  }
}

class LineEditApplication {
  const LineEditApplication({required this.text, required this.result});

  final String text;
  final EditResult result;
}

LineEditApplication applyLineEdits({
  required String source,
  required List<EditOp> edits,
  required int sizeBefore,
}) {
  if (edits.isEmpty) {
    return LineEditApplication(
      text: source,
      result: EditResult.error(
        code: 'NO_EDITS',
        message: 'edit requires at least one edit',
        sizeBefore: sizeBefore,
        sizeAfter: sizeBefore,
      ),
    );
  }

  final originalLines = _parseTextLines(source);
  final lineCount = originalLines.length;
  for (var i = 0; i < edits.length; i++) {
    final edit = edits[i];
    final end = edit.resolvedEndLine;
    if (edit.startLine < 1) {
      return LineEditApplication(
        text: source,
        result: EditResult.error(
          code: 'INVALID_START_LINE',
          message: 'start_line must be >= 1',
          failedIndex: i,
          startLine: edit.startLine,
          endLine: end,
          sizeBefore: sizeBefore,
          sizeAfter: sizeBefore,
        ),
      );
    }
    if (end < edit.startLine) {
      return LineEditApplication(
        text: source,
        result: EditResult.error(
          code: 'INVALID_LINE_RANGE',
          message: 'end_line must be greater than or equal to start_line',
          failedIndex: i,
          startLine: edit.startLine,
          endLine: end,
          sizeBefore: sizeBefore,
          sizeAfter: sizeBefore,
        ),
      );
    }
    if (edit.startLine > lineCount || end > lineCount) {
      return LineEditApplication(
        text: source,
        result: EditResult.error(
          code: 'LINE_OUT_OF_RANGE',
          message:
              'line range $edit.startLine-$end is outside the file '
              '(file has $lineCount lines)',
          failedIndex: i,
          startLine: edit.startLine,
          endLine: end,
          sizeBefore: sizeBefore,
          sizeAfter: sizeBefore,
        ),
      );
    }
  }

  for (var i = 0; i < edits.length; i++) {
    for (var j = i + 1; j < edits.length; j++) {
      final firstEnd = edits[i].resolvedEndLine;
      final secondEnd = edits[j].resolvedEndLine;
      if (edits[i].startLine <= secondEnd && edits[j].startLine <= firstEnd) {
        return LineEditApplication(
          text: source,
          result: EditResult.error(
            code: 'OVERLAPPING_EDITS',
            message:
                'edit ranges overlap: '
                '${edits[i].startLine}-$firstEnd and '
                '${edits[j].startLine}-$secondEnd',
            failedIndex: j,
            startLine: edits[j].startLine,
            endLine: secondEnd,
            sizeBefore: sizeBefore,
            sizeAfter: sizeBefore,
          ),
        );
      }
    }
  }

  final order = List<int>.generate(edits.length, (i) => i)
    ..sort((a, b) {
      final start = edits[b].startLine.compareTo(edits[a].startLine);
      if (start != 0) return start;
      return edits[b].resolvedEndLine.compareTo(edits[a].resolvedEndLine);
    });
  final updatedLines = originalLines
      .map((line) => _TextLine(line.content, line.ending))
      .toList();
  final diffs = List<EditDiffEntry?>.filled(edits.length, null);

  for (final index in order) {
    final edit = edits[index];
    final start = edit.startLine - 1;
    final end = edit.resolvedEndLine;
    final oldLines = originalLines.sublist(start, end);
    final oldPreview = _previewText(_renderTextLines(oldLines));
    final replacement = _parseTextLines(edit.content, emptyAsLine: false);
    if (replacement.isNotEmpty && replacement.last.ending.isEmpty) {
      replacement.last.ending = originalLines[end - 1].ending;
    }
    updatedLines.replaceRange(start, end, replacement);
    diffs[index] = EditDiffEntry(
      editIndex: index,
      startLine: edit.startLine,
      endLine: end,
      oldPreview: oldPreview,
      newPreview: _previewText(edit.content),
      replacements: end - edit.startLine + 1,
    );
  }

  final updated = _renderTextLines(updatedLines);
  return LineEditApplication(
    text: updated,
    result: EditResult.success(
      applied: edits.length,
      sizeBefore: sizeBefore,
      sizeAfter: utf8.encode(updated).length,
      diff: diffs.cast<EditDiffEntry>(),
    ),
  );
}

List<String> splitTextLines(String text) {
  return _parseTextLines(text).map((line) => line.content).toList();
}

class _TextLine {
  _TextLine(this.content, this.ending);

  final String content;
  String ending;
}

List<_TextLine> _parseTextLines(String text, {bool emptyAsLine = true}) {
  if (text.isEmpty) {
    return emptyAsLine ? [_TextLine('', '')] : <_TextLine>[];
  }
  final lines = <_TextLine>[];
  var start = 0;
  var i = 0;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x0a || unit == 0x0d) {
      final ending =
          unit == 0x0d && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0a
          ? '\r\n'
          : String.fromCharCode(unit);
      lines.add(_TextLine(text.substring(start, i), ending));
      i += ending.length;
      start = i;
      continue;
    }
    i += 1;
  }
  if (start < text.length) {
    lines.add(_TextLine(text.substring(start), ''));
  }
  return lines;
}

String _renderTextLines(List<_TextLine> lines) {
  final buffer = StringBuffer();
  for (final line in lines) {
    buffer
      ..write(line.content)
      ..write(line.ending);
  }
  return buffer.toString();
}

String _previewText(String text) {
  var flat = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  flat = flat.replaceAll('\n', '\\n');
  if (flat.length > 120) flat = '${flat.substring(0, 120)}...';
  return flat;
}

/// Parses a `working://...` URI into its relative path
/// segments. Returns `null` for non-`working://` inputs.
///
/// `working:///abs/path` is treated as the absolute path
/// `/abs/path` (the three slashes fold to one), so the model
/// can pass through absolute paths that the FileService will
/// then validate against the configured working directory.
/// Pure relative paths (`working://foo/bar`) resolve to
/// `<workingDir>/foo/bar`.
({List<String> segments, String? absoluteOverride})? parseWorkingPath(
  String input,
) {
  if (!isWorkingPath(input)) return null;
  final body = input.substring('working://'.length);
  if (body.isEmpty) {
    return (segments: const <String>[], absoluteOverride: null);
  }
  // `working:///abs/path` -> absolute override, no segments.
  if (body.startsWith('/')) {
    return (segments: const <String>[], absoluteOverride: body);
  }
  final segments = body
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  return (segments: segments, absoluteOverride: null);
}
