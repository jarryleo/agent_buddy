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
