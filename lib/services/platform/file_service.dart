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

  /// Apply a batch of exact-text edits to the file at [path].
  /// One atomic operation: either every edit is applied and the
  /// result is written, or nothing is written and the failure
  /// details are returned.
  ///
  /// Use this instead of [read] + [write] when the model wants
  /// to change code / text. Token cost stays proportional to
  /// the **changed** content, not the file size.
  ///
  /// Each [EditOp] is matched by literal text (not regex); the
  /// edit is a single global find / replace.
  /// * [EditOp.oldText] must be unique in the file unless
  ///   [EditOp.globalReplace] is `true`.
  /// * [EditOp.newText] may be empty (= delete the matched
  ///   block).
  /// * All edits are validated up front; the file is only
  ///   written if every edit would succeed. Otherwise
  ///   [EditResult.ok] is `false` and [EditResult.failedIndex]
  ///   points at the first bad edit.
  /// * Edits are applied in the order the model passed them.
  ///   When two edits touch overlapping text, the *first* edit
  ///   runs against the original text; the *second* edit is
  ///   re-matched against the post-first-edit text.
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

/// A single exact-text edit, supplied to [FileService.edit].
///
/// Anchor matching is **literal**, not regex: [oldText] is found
/// in the file with `String.indexOf` and replaced. There is no
/// escaping of `$` / `\`, no `\n` interpretation, and no glob
/// expansion. The model is expected to copy the anchor text
/// verbatim from a prior `file read` response (which is why
/// `file read` returns content with a 1-indexed line-number
/// prefix and explicit `\n` separators).
class EditOp {
  const EditOp({
    required this.oldText,
    this.newText = '',
    this.globalReplace = false,
  });

  /// The text to find. Must be unique in the file unless
  /// [globalReplace] is `true`. An empty string is rejected
  /// (would match every position).
  final String oldText;

  /// The replacement text. Empty string deletes the matched
  /// block.
  final String newText;

  /// When `true`, every occurrence of [oldText] is replaced
  /// (useful for renaming a symbol across the whole file).
  /// Defaults to `false`, which requires the anchor to be
  /// unique - the safe default that prevents accidental
  /// mass-changes.
  final bool globalReplace;

  /// Decode one [EditOp] from the JSON shape the `file` tool's
  /// `edit` action accepts. Throws [FormatException] for
  /// malformed input so the model gets a clear error.
  factory EditOp.fromJson(Map<String, dynamic> json) {
    final oldText = json['old_text'];
    if (oldText is! String) {
      throw const FormatException(
        'edit: old_text is required and must be a string',
      );
    }
    if (oldText.isEmpty) {
      throw const FormatException('edit: old_text must be a non-empty string');
    }
    final newText = json['new_text'];
    if (newText != null && newText is! String) {
      throw const FormatException('edit: new_text must be a string');
    }
    final global = json['global_replace'];
    if (global != null && global is! bool) {
      throw const FormatException('edit: global_replace must be a boolean');
    }
    return EditOp(
      oldText: oldText,
      newText: (newText as String?) ?? '',
      globalReplace: (global as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'old_text': oldText,
    'new_text': newText,
    'global_replace': globalReplace,
  };
}

/// Outcome of a [FileService.edit] call. When [ok] is `false`
/// the file is **not** modified and [failedIndex] points at the
/// first [EditOp] that could not be applied; the rest of the
/// envelope explains why.
class EditResult {
  const EditResult._({
    required this.ok,
    required this.applied,
    this.failedIndex,
    this.errorCode,
    this.errorMessage,
    this.sizeBefore,
    this.sizeAfter,
    this.diff = const [],
    this.nearMatches = const [],
    this.candidates = const [],
  });

  /// Build a success envelope.
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

  /// `old_text` was not found anywhere in the file. The
  /// [nearMatches] list carries a few line-anchored excerpts of
  /// the closest matches so the model can self-correct.
  factory EditResult.notFound({
    required int failedIndex,
    required int sizeBefore,
    required List<EditNearMatch> nearMatches,
  }) {
    return EditResult._(
      ok: false,
      applied: 0,
      failedIndex: failedIndex,
      errorCode: 'OLD_TEXT_NOT_FOUND',
      errorMessage:
          'old_text was not found in the file; '
          'see near_matches for the closest locations',
      sizeBefore: sizeBefore,
      sizeAfter: sizeBefore,
      nearMatches: nearMatches,
    );
  }

  /// `old_text` matched more than once and `global_replace`
  /// was `false`. The [candidates] list pinpoints every match
  /// by line number so the model can extend the anchor.
  factory EditResult.notUnique({
    required int failedIndex,
    required int sizeBefore,
    required int foundCount,
    required List<EditCandidate> candidates,
  }) {
    return EditResult._(
      ok: false,
      applied: 0,
      failedIndex: failedIndex,
      errorCode: 'OLD_TEXT_NOT_UNIQUE',
      errorMessage:
          'old_text matched $foundCount times; '
          'add more surrounding context to make it unique, or '
          'set global_replace=true',
      sizeBefore: sizeBefore,
      sizeAfter: sizeBefore,
      candidates: candidates,
    );
  }

  /// Some other failure (file missing, IO error, ...).
  factory EditResult.error({required String code, required String message}) {
    return EditResult._(
      ok: false,
      applied: 0,
      errorCode: code,
      errorMessage: message,
    );
  }

  /// `true` when every edit was applied and the file was
  /// written successfully.
  final bool ok;

  /// Number of edits that were actually applied. `applied ==
  /// edits.length` on success, `0` on failure (no partial
  /// writes — the whole batch is atomic).
  final int applied;

  /// 0-indexed position of the first edit that could not be
  /// applied, when [ok] is `false`. `null` when [ok] is `true`.
  final int? failedIndex;

  /// A short machine-readable code: `OLD_TEXT_NOT_FOUND`,
  /// `OLD_TEXT_NOT_UNIQUE`, `PATH_NOT_FOUND`, `BRIDGE_ERROR`,
  /// ...
  final String? errorCode;

  /// A human-readable explanation. Localised on the Dart side
  /// when surfaced to the model via the `file` tool envelope.
  final String? errorMessage;

  /// File size in bytes **before** the edit, when known.
  final int? sizeBefore;

  /// File size in bytes **after** the edit, when known.
  final int? sizeAfter;

  /// Per-edit preview of the change. Empty on failure.
  final List<EditDiffEntry> diff;

  /// Up to 3 line-anchored excerpts of the closest matches
  /// when [errorCode] is `OLD_TEXT_NOT_FOUND`. Empty
  /// otherwise.
  final List<EditNearMatch> nearMatches;

  /// Every match location when [errorCode] is
  /// `OLD_TEXT_NOT_UNIQUE`. Capped at 10 to keep the response
  /// small.
  final List<EditCandidate> candidates;
}

/// One row of [EditResult.diff] — a per-edit preview of what
/// changed. The [oldPreview] / [newPreview] fields are
/// truncated to a fixed length so the response stays small
/// even when the model edits a 1000-line block.
class EditDiffEntry {
  const EditDiffEntry({
    required this.editIndex,
    required this.matchedLine,
    required this.oldPreview,
    required this.newPreview,
    required this.replacements,
  });

  final int editIndex;
  final int matchedLine;
  final String oldPreview;
  final String newPreview;

  /// How many replacements this edit actually applied (1 for
  /// non-`global_replace`, N for `global_replace`).
  final int replacements;
}

/// A line-anchored excerpt shown in
/// [EditResult.nearMatches]. The model can re-`read` the
/// suggested line range to get the exact bytes back.
class EditNearMatch {
  const EditNearMatch({required this.line, required this.preview});
  final int line;
  final String preview;
}

/// One match location shown in [EditResult.candidates].
class EditCandidate {
  const EditCandidate({required this.line, required this.preview});
  final int line;
  final String preview;
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
