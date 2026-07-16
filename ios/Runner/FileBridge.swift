import Flutter
import Foundation
import UIKit
import UniformTypeIdentifiers

/// MethodChannel bridge for the iOS `file` tool.
///
/// Channel: `agent_buddy/file`
///
/// Methods:
///   - pick({mime_type?, read_only?}) -> {id, name, size, mime_type, path}
///       OR {cancelled: true} when the user backs out.
///       The call is **parked** until the system document picker
///       resolves; never returns a transient error before the
///       user has had a chance to answer. Cancels are surfaced
///       as a soft payload, not an exception, so the model can
///       pivot to a different approach (e.g. use the sandbox).
///   - release({id}) -> void. Drops the in-memory mapping +
///       `stopAccessingSecurityScopedResource` for the
///       underlying URL.
///   - readPicker({id, max_bytes}) -> Uint8List (FlutterData)
///   - writePicker({id, bytes, append?}) -> void
///   - readAttrPicker({id}) -> {type, size, ...}
///
/// Permission flow:
///   **No iOS permission description is required for the
///   document picker.** `UIDocumentPickerViewController` is a
///   system-managed UI that handles its own authorization —
///   the user just picks a file, the system grants per-URL
///   access (security-scoped), and the app can read/write that
///   URL until `stopAccessingSecurityScopedResource` is called.
///   Files that are picked are also copied into the app's
///   inbox-style temp dir by the system, so we get a stable
///   `file://` URL we can hand to the chat provider.
///
/// Concurrency: at most one picker visible at a time. Multiple
/// pick() calls while a picker is up are queued in
/// [pendingPicks] and resumed in order. Mirrors the
/// permission-park pattern used by LocationBridge /
/// CalendarBridge / RemindersBridge.
public class FileBridge: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  public static let channelName = "agent_buddy/file"

  private let stateLock = NSLock()
  private var pickedById: [String: Picked] = [:]
  private var pendingPicks: [String: PendingPick] = [:]
  private var pickSeq: Int = 0
  private var activeCallId: String?

  private var flutterResult: FlutterResult?
  private var presentingController: UIViewController?

  private struct Picked {
    let url: URL
    let displayName: String
    let size: Int64
    let mimeType: String?
  }

  private struct PendingPick {
    let result: FlutterResult
    let mimeType: String?
    let readOnly: Bool
    var delivered: Bool
    let fireLock: NSLock
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = FileBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "pick":
      let args = call.arguments as? [String: Any] ?? [:]
      let mimeType = (args["mime_type"] as? String)?.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      let readOnly = args["read_only"] as? Bool ?? false
      handlePick(
        mimeType: (mimeType?.isEmpty == false) ? mimeType : nil,
        readOnly: readOnly,
        result: result
      )
    case "release":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      if id.isEmpty {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "id is required", details: nil))
        return
      }
      handleRelease(id: id, result: result)
    case "readPicker":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      let maxBytes = (args["max_bytes"] as? NSNumber)?.int64Value
        ?? Int64(2 * 1024 * 1024)
      if id.isEmpty {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "id is required", details: nil))
        return
      }
      handleReadPicker(id: id, maxBytes: maxBytes, result: result)
    case "writePicker":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      let flutterBytes = args["bytes"] as? FlutterStandardTypedData
      if id.isEmpty {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "id is required", details: nil))
        return
      }
      guard let bytes = flutterBytes else {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "bytes is required", details: nil))
        return
      }
      handleWritePicker(id: id, bytes: bytes.data, result: result)
    case "readAttrPicker":
      let args = call.arguments as? [String: Any] ?? [:]
      let id = args["id"] as? String ?? ""
      if id.isEmpty {
        result(FlutterError(code: "INVALID_ARGUMENT", message: "id is required", details: nil))
        return
      }
      handleReadAttrPicker(id: id, result: result)
    case "ensurePermission":
      // iOS document picker handles its own grant; no permission
      // to check outside of pick(). Surface NOT_SUPPORTED so any
      // probe is answered clearly.
      result(FlutterError(
        code: "NOT_SUPPORTED",
        message: "ensurePermission is not used by the file tool: "
          + "UIDocumentPickerViewController grants per-URL access without any "
          + "iOS permission description",
        details: nil
      ))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - pick

  private func handlePick(
    mimeType: String?,
    readOnly: Bool,
    result: @escaping FlutterResult
  ) {
    stateLock.lock()
    pickSeq += 1
    let callId = "f-\(pickSeq)"
    pendingPicks[callId] = PendingPick(
      result: result,
      mimeType: mimeType,
      readOnly: readOnly,
      delivered: false,
      fireLock: NSLock()
    )
    if activeCallId != nil {
      // A picker is already up; queue behind it. The id is
      // already reserved so a later `readPicker(id)` won't
      // collide with a future pick.
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    launchPicker(callId: callId)
  }

  private func launchPicker(callId: String) {
    stateLock.lock()
    guard let pending = pendingPicks[callId] else {
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    activeCallId = callId

    // Map a small set of model-friendly MIME shortcuts to the
    // matching UTType. Anything else goes through "item" so the
    // picker shows all document types. The system copy the
    // picked file into the app's temp dir; we own the local URL
    // for as long as the user doesn't release it.
    let utType: UTType
    if let mime = pending.mimeType {
      utType = utTypeForMime(mime)
    } else {
      utType = .item
    }

    let picker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [utType], asCopy: true)
    } else {
      picker = UIDocumentPickerViewController(documentTypes: [utType.identifier], in: .import)
    }
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard let root = self.topViewController() else {
        self.stateLock.lock()
        self.activeCallId = nil
        let p = self.pendingPicks.removeValue(forKey: callId)
        self.stateLock.unlock()
        p?.fireLock.lock()
        if !(p?.delivered ?? true) {
          p?.delivered = true
          p?.fireLock.unlock()
          p?.result(FlutterError(
            code: "NOT_SUPPORTED",
            message: "no view controller available to present the file picker",
            details: nil
          ))
          self.drainQueue()
        } else {
          p?.fireLock.unlock()
        }
        return
      }
      self.presentingController = root
      self.flutterResult = pending.result
      root.present(picker, animated: true, completion: nil)
    }
  }

  private func drainQueue() {
    stateLock.lock()
    let next = pendingPicks.keys.sorted { pickSeqOf($0) < pickSeqOf($1) }.first
    stateLock.unlock()
    if let next = next {
      launchPicker(callId: next)
    }
  }

  private func pickSeqOf(_ callId: String) -> Int {
    return Int(callId.dropFirst(2)) ?? Int.max
  }

  // MARK: - UIDocumentPickerDelegate

  public func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    let callId = activeCallId
    activeCallId = nil
    defer { drainQueue() }
    guard let callId = callId else { return }

    stateLock.lock()
    let pending = pendingPicks.removeValue(forKey: callId)
    stateLock.unlock()
    guard let pending = pending else { return }

    pending.fireLock.lock()
    if pending.delivered {
      pending.fireLock.unlock()
      return
    }

    guard let url = urls.first else {
      pending.delivered = true
      pending.fireLock.unlock()
      pending.result(["cancelled": true])
      return
    }

    // Security-scoped resource: the system grants access only
    // while we hold the start/stop pair. We call start here and
    // stop in handleRelease.
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart {
        // Don't stop here — release will. The model is expected
        // to call release(id) when done.
      }
    }

    let displayName = url.lastPathComponent
    let size = fileSize(at: url)
    let mime = mimeTypeForURL(url)
    let id = callId
    pickedById[id] = Picked(
      url: url,
      displayName: displayName,
      size: size,
      mimeType: mime
    )

    pending.delivered = true
    pending.fireLock.unlock()
    pending.result([
      "id": id,
      "name": displayName,
      "size": size,
      "mime_type": mime as Any,
      "path": "picker://\(id)",
    ])
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callId = activeCallId
    activeCallId = nil
    defer { drainQueue() }
    guard let callId = callId else { return }
    stateLock.lock()
    let pending = pendingPicks.removeValue(forKey: callId)
    stateLock.unlock()
    guard let pending = pending else { return }

    pending.fireLock.lock()
    if pending.delivered {
      pending.fireLock.unlock()
      return
    }
    pending.delivered = true
    pending.fireLock.unlock()
    pending.result(["cancelled": true])
  }

  // MARK: - release

  private func handleRelease(id: String, result: @escaping FlutterResult) {
    stateLock.lock()
    let picked = pickedById.removeValue(forKey: id)
    stateLock.unlock()
    if let picked = picked {
      picked.url.stopAccessingSecurityScopedResource()
    }
    result(nil)
  }

  // MARK: - readPicker

  private func handleReadPicker(
    id: String,
    maxBytes: Int64,
    result: @escaping FlutterResult
  ) {
    stateLock.lock()
    let picked = pickedById[id]
    stateLock.unlock()
    guard let picked = picked else {
      result(FlutterError(
        code: "PATH_NOT_FOUND",
        message: "picker id not found or already released: \(id)",
        details: nil
      ))
      return
    }
    do {
      let data = try readWithCap(url: picked.url, maxBytes: maxBytes)
      result(FlutterStandardTypedData(bytes: data))
    } catch let FileReadError.tooLarge(msg) {
      result(FlutterError(code: "FILE_TOO_LARGE", message: msg, details: nil))
    } catch let FileReadError.io(msg) {
      result(FlutterError(code: "BRIDGE_ERROR", message: msg, details: nil))
    } catch {
      result(FlutterError(
        code: "BRIDGE_ERROR",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  // MARK: - writePicker

  private func handleWritePicker(
    id: String,
    bytes: Data,
    result: @escaping FlutterResult
  ) {
    stateLock.lock()
    let picked = pickedById[id]
    stateLock.unlock()
    guard let picked = picked else {
      result(FlutterError(
        code: "PATH_NOT_FOUND",
        message: "picker id not found or already released: \(id)",
        details: nil
      ))
      return
    }
    do {
      try bytes.write(to: picked.url, options: .atomic)
      result(nil)
    } catch {
      result(FlutterError(
        code: "BRIDGE_ERROR",
        message: "write failed: \(error.localizedDescription)",
        details: nil
      ))
    }
  }

  // MARK: - readAttrPicker

  private func handleReadAttrPicker(id: String, result: @escaping FlutterResult) {
    stateLock.lock()
    let picked = pickedById[id]
    stateLock.unlock()
    guard let picked = picked else {
      result(FlutterError(
        code: "PATH_NOT_FOUND",
        message: "picker id not found or already released: \(id)",
        details: nil
      ))
      return
    }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    result([
      "type": "file",
      "size": picked.size,
      "modified_ms": now,
      "accessed_ms": now,
      "changed_ms": now,
      "is_directory": false,
      "is_file": true,
      "is_link": false,
    ])
  }

  // MARK: - helpers

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let window = scenes
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private func fileSize(at url: URL) -> Int64 {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attrs?[.size] as? NSNumber {
      return size.int64Value
    }
    return -1
  }

  private func mimeTypeForURL(_ url: URL) -> String? {
    if #available(iOS 14.0, *) {
      if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
        return type
      }
    }
    return nil
  }

  private func utTypeForMime(_ mime: String) -> UTType {
    if let type = UTType(mimeType: mime) {
      return type
    }
    if mime == "text/*" { return .text }
    if mime == "image/*" { return .image }
    if mime == "audio/*" { return .audio }
    if mime == "video/*" { return .movie }
    return .item
  }

  private enum FileReadError: Error {
    case tooLarge(String)
    case io(String)
  }

  private func readWithCap(url: URL, maxBytes: Int64) throws -> Data {
    // Stream the file in chunks so we can cap the read size
    // without allocating the whole file when the cap is small.
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw FileReadError.io("open failed: \(error.localizedDescription)")
    }
    defer { try? handle.close() }

    let bufSize = 32 * 1024
    var collected = Data()
    var total: Int64 = 0
    while true {
      let chunk = handle.readData(ofLength: bufSize)
      if chunk.isEmpty { break }
      total += Int64(chunk.count)
      if total > maxBytes {
        throw FileReadError.tooLarge(
          "file exceeds max_bytes=\(maxBytes); raise the limit if you really need it"
        )
      }
      collected.append(chunk)
    }
    return collected
  }
}
