import '../../models/picked_file.dart';

/// Abstract surface for the platform file service. On Android /
/// iOS the implementation talks to the native bridge for SAF /
/// `UIDocumentPickerViewController` ops and uses `path_provider`
/// + `dart:io` for the app's own sandbox; on web / non-supported
/// platforms the stub returns `UnsupportedError` for picker-backed
/// ops and a no-op (or in-memory fake) for the rest.
///
/// Path schemes the model is allowed to pass:
///   * `app://documents/...` — `getApplicationDocumentsDirectory()`
///   * `app://temp/...`      — `getTemporaryDirectory()`
///   * `app://support/...`   — `getApplicationSupportDirectory()`
///   * `picker://<id>`       — a file the user picked via [pick]
///
/// Anything else (raw absolute path on mobile, `file://`, `content://`)
/// is rejected with an error — the model should never see the
/// underlying OS path. The schema enforces this; the service
/// double-checks.
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
  /// append mode to third-party apps — use [read] + [write]
  /// round-trip instead).
  Future<void> write(String path, List<int> bytes, {bool append = false});

  /// Delete a file or directory. Rejects `picker://<id>` paths
  /// — the picker grants per-URI access for read/write, not
  /// arbitrary delete on the user's filesystem. Use [release]
  /// to drop the local handle instead.
  Future<void> delete(String path, {bool recursive = false});

  /// Rename / move. Rejects `picker://<id>` paths for the same
  /// reason as [delete] — we can't move a file inside someone
  /// else's directory tree.
  Future<void> rename(String from, String to);

  /// List a directory. Only valid against `app://...` paths
  /// (we can't list a SAF directory unless the user picked it
  /// with the directory picker, which is out of scope here).
  /// Returns at most 200 entries (matches the desktop
  /// `FileTool._listDir` cap).
  Future<List<FileEntry>> listDir(String path, {bool recursive = false});

  /// Read attributes. Valid against both `app://` and `picker://`.
  Future<FileAttrs> readAttr(String path);
}

/// Test / web factory signature. Defaults to a fresh
/// [FileService] on mobile, a stub elsewhere.
typedef FileServiceBuilder = FileService Function();

/// True when [input] is a `picker://<id>` reference. The bridge
/// keeps the id → native-URI map in-process; the model only ever
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

/// One of the three sandbox roots the model is allowed to
/// address via `app://<root>/...` URIs.
enum AppSandbox { documents, temp, support }

/// Parses an `app://documents/...` URI and returns the matching
/// sandbox root + relative path segments. Returns `null` for
/// non-`app://` URIs or unknown roots.
({AppSandbox root, List<String> segments})? parseAppPath(String input) {
  if (input.length < 8) return null; // `app://x/`
  if (!input.startsWith('app://')) return null;
  final uri = Uri.parse(input);
  if (uri.scheme != 'app') return null;
  final host = uri.host;
  final AppSandbox root;
  switch (host) {
    case 'documents':
      root = AppSandbox.documents;
    case 'temp':
      root = AppSandbox.temp;
    case 'support':
      root = AppSandbox.support;
    default:
      return null;
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return (root: root, segments: segments);
}
