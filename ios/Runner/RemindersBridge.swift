import EventKit
import Flutter
import Foundation

/// MethodChannel bridge for the iOS Reminders framework. Mirrors
/// the `agent_buddy/reminders` protocol. iOS gives us a real
/// to-do store via `EKReminder`, so unlike Android we don't
/// piggy-back on calendars.
///
/// Permission flow mirrors `CalendarBridge` and `LocationBridge`:
/// every concurrent call is parked in a per-call pending map so
/// the user's tap on the system dialog resumes **all** of them —
/// not just the most recent one. This avoids the "tool call fails
/// before the user can answer" race when the model fires multiple
/// tool calls in quick succession.
public class RemindersBridge: NSObject, FlutterPlugin {
  public static let channelName = "agent_buddy/reminders"

  private let store = EKEventStore()
  private var pendingByCallId: [String: Pending] = [:]
  private var nextCallSeq: Int = 0
  private let stateLock = NSLock()
  private var requestInFlight: Bool = false

  private struct Pending {
    let result: FlutterResult
    let method: String
    let args: [String: Any]
    let fireLock: NSLock
    var delivered: Bool
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = RemindersBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ensurePermission":
      // Pure read; respond synchronously.
      result(["granted": store.authorizationStatus(for: .reminder) == .fullAccess])
    case "listCalendars":
      // iOS doesn't expose the "pick a calendar" picker flow that
      // Android needs. We still implement the method so the Dart
      // side gets a non-empty list back; the picker sheet is a
      // no-op on iOS because the system Reminders app handles
      // the default list.
      result(self.listWritableCalendars())
    case "setTodoCalendar", "getTodoCalendar":
      // No-op on iOS: the system Reminders framework has a single
      // canonical store. The Dart side knows this and short-
      // circuits the picker sheet.
      if call.method == "getTodoCalendar" {
        result("ios_default")
      } else {
        result(["ok": true])
      }
    case "listReminders":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "createReminder":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "completeReminder":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "updateReminder":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "deleteReminder":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Permission dispatcher

  private func parkOrDispatch(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult,
    method: String,
    args: [String: Any]
  ) {
    let status = store.authorizationStatus(for: .reminder)
    if status == .fullAccess {
      DispatchQueue.main.async { [weak self] in
        self?.dispatch(method: method, args: args, originalResult: result)
      }
      return
    }
    if status == .denied || status == .restricted {
      // The user has permanently denied access; don't pop another
      // dialog. Surface PERMANENTLY_DENIED so the AI can hint at
      // system settings.
      result(
        FlutterError(
          code: "PERMANENTLY_DENIED",
          message: "Reminders permission permanently denied; open system settings to enable it",
          details: nil
        )
      )
      return
    }
    // .notDetermined: ask. Park the call.
    let callId = registerPending(result: result, method: method, args: args)
    requestAccessIfNeeded(callId: callId)
  }

  private func registerPending(
    result: @escaping FlutterResult,
    method: String,
    args: [String: Any]
  ) -> String {
    stateLock.lock()
    nextCallSeq += 1
    let callId = "rem-\(nextCallSeq)"
    pendingByCallId[callId] = Pending(
      result: result,
      method: method,
      args: args,
      fireLock: NSLock(),
      delivered: false
    )
    stateLock.unlock()
    return callId
  }

  private func requestAccessIfNeeded(callId: String) {
    stateLock.lock()
    let inFlight = requestInFlight
    if !inFlight { requestInFlight = true }
    stateLock.unlock()
    if inFlight { return }

    if #available(iOS 17.0, *) {
      Task { @MainActor in
        _ = try? await self.store.requestFullAccessToReminders()
        DispatchQueue.main.async { [weak self] in
          self?.resumeAllPending()
        }
      }
    } else {
      self.store.requestAccess(to: .reminder) { [weak self] _, _ in
        DispatchQueue.main.async {
          self?.resumeAllPending()
        }
      }
    }
  }

  private func resumeAllPending() {
    stateLock.lock()
    requestInFlight = false
    let status = self.store.authorizationStatus(for: .reminder)
    let snapshot = self.pendingByCallId
    stateLock.unlock()

    switch status {
    case .fullAccess:
      for (cid, _) in snapshot {
        self.deliverResume(cid)
      }
    case .denied, .restricted:
      for (cid, _) in snapshot {
        self.deliverError(
          cid,
          code: "PERMANENTLY_DENIED",
          message: "Reminders permission permanently denied; open system settings to enable it"
        )
      }
    case .notDetermined:
      for (cid, _) in snapshot {
        self.deliverError(
          cid,
          code: "PERMISSION_DENIED",
          message: "Reminders permission dialog was dismissed without a decision."
        )
      }
    @unknown default:
      for (cid, _) in snapshot {
        self.deliverError(
          cid,
          code: "PERMISSION_DENIED",
          message: "Reminders permission state is unknown."
        )
      }
    }
  }

  private func deliverResume(_ callId: String) {
    stateLock.lock()
    guard var p = pendingByCallId[callId] else {
      stateLock.unlock()
      return
    }
    p.fireLock.lock()
    if p.delivered {
      p.fireLock.unlock()
      stateLock.unlock()
      return
    }
    p.delivered = true
    p.fireLock.unlock()
    pendingByCallId.removeValue(forKey: callId)
    stateLock.unlock()
    dispatch(method: p.method, args: p.args, originalResult: p.result)
  }

  private func deliverError(_ callId: String, code: String, message: String) {
    stateLock.lock()
    guard var p = pendingByCallId[callId] else {
      stateLock.unlock()
      return
    }
    p.fireLock.lock()
    if p.delivered {
      p.fireLock.unlock()
      stateLock.unlock()
      return
    }
    p.delivered = true
    p.fireLock.unlock()
    pendingByCallId.removeValue(forKey: callId)
    stateLock.unlock()
    p.result(FlutterError(code: code, message: message, details: nil))
  }

  // MARK: - Dispatch (already authorized path)

  private func dispatch(
    method: String,
    args: [String: Any],
    originalResult: @escaping FlutterResult
  ) {
    switch method {
    case "listReminders":
      let includeCompleted = args["includeCompleted"] as? Bool ?? false
      let max = (args["max"] as? NSNumber)?.intValue ?? 50
      // fetchReminders invokes its callback synchronously on the
      // calling thread, so we hop to a background queue to avoid
      // blocking the main thread.
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let reminders = try self.listReminders(
            includeCompleted: includeCompleted,
            max: max
          )
          DispatchQueue.main.async { originalResult(reminders) }
        } catch let err as BridgeError {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: err.code, message: err.message, details: nil))
          }
        } catch {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "createReminder":
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let r = try self.createReminder(args: args)
          DispatchQueue.main.async { originalResult(r) }
        } catch let err as BridgeError {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: err.code, message: err.message, details: nil))
          }
        } catch {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "completeReminder":
      let id = args["id"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let r = try self.completeReminder(id: id)
          DispatchQueue.main.async { originalResult(r as Any) }
        } catch let err as BridgeError {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: err.code, message: err.message, details: nil))
          }
        } catch {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "updateReminder":
      let id = args["id"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let r = try self.updateReminder(id: id, args: args)
          DispatchQueue.main.async { originalResult(r as Any) }
        } catch let err as BridgeError {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: err.code, message: err.message, details: nil))
          }
        } catch {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "deleteReminder":
      let id = args["id"] as? String ?? ""
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        do {
          let ok = try self.deleteReminder(id: id)
          DispatchQueue.main.async { originalResult(["ok": ok]) }
        } catch let err as BridgeError {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: err.code, message: err.message, details: nil))
          }
        } catch {
          DispatchQueue.main.async {
            originalResult(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
          }
        }
      }
    default:
      originalResult(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Calendar listing (iOS shim)

  private func listWritableCalendars() -> [[String: Any]] {
    let cals = store.calendars(for: .reminder)
    return cals.map { cal in
      [
        "id": cal.calendarIdentifier,
        "displayName": cal.title,
        "accountName": cal.source?.title ?? "",
      ]
    }
  }

  // MARK: - Reminder CRUD

  private func listReminders(includeCompleted: Bool, max: Int) throws -> [[String: Any]] {
    let cals = store.calendars(for: .reminder)
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: nil,
      calendars: cals
    )
    // Caller is responsible for hopping off the main thread before
    // calling us; fetchReminders invokes its callback synchronously.
    var mapped: [[String: Any]] = []
    let semaphore = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: predicate) { ekReminders in
      let filtered = (ekReminders ?? []).filter { includeCompleted || !$0.isCompleted }
      mapped = filtered.prefix(max).map { self.reminderToDict($0) }
      semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 10) == .timedOut {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "fetchReminders timed out"
      )
    }
    return mapped
  }

  private func createReminder(args: [String: Any]) throws -> [String: Any] {
    let title = args["title"] as? String ?? ""
    if title.isEmpty {
      throw BridgeError(code: "INVALID_ARGUMENT", message: "title required")
    }
    let notes = args["notes"] as? String
    let dueMs = (args["dueMs"] as? NSNumber)?.int64Value
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.notes = notes
    reminder.calendar = store.defaultCalendarForNewReminders()
    if let dueMs = dueMs {
      let date = Date(timeIntervalSince1970: TimeInterval(dueMs) / 1000.0)
      let comps = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: date
      )
      reminder.dueDateComponents = comps
    }
    do {
      try store.save(reminder, commit: true)
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to save reminder: \(error.localizedDescription)"
      )
    }
    return reminderToDict(reminder)
  }

  private func completeReminder(id: String) throws -> [String: Any]? {
    guard let calItem = store.calendarItem(withIdentifier: id) as? EKReminder else {
      return nil
    }
    calItem.isCompleted = true
    do {
      try store.save(calItem, commit: true)
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to complete reminder: \(error.localizedDescription)"
      )
    }
    return reminderToDict(calItem)
  }

  private func updateReminder(id: String, args: [String: Any]) throws -> [String: Any]? {
    guard let calItem = store.calendarItem(withIdentifier: id) as? EKReminder else {
      return nil
    }
    if let title = args["title"] as? String { calItem.title = title }
    if let notes = args["notes"] as? String { calItem.notes = notes }
    if let dueMs = (args["dueMs"] as? NSNumber)?.int64Value {
      let date = Date(timeIntervalSince1970: TimeInterval(dueMs) / 1000.0)
      let comps = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: date
      )
      calItem.dueDateComponents = comps
    }
    do {
      try store.save(calItem, commit: true)
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to update reminder: \(error.localizedDescription)"
      )
    }
    return reminderToDict(calItem)
  }

  private func deleteReminder(id: String) throws -> Bool {
    guard let calItem = store.calendarItem(withIdentifier: id) as? EKReminder else {
      return false
    }
    do {
      try store.remove(calItem, commit: true)
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to delete reminder: \(error.localizedDescription)"
      )
    }
    return true
  }

  // MARK: - Mapping

  private func reminderToDict(_ r: EKReminder) -> [String: Any] {
    var dict: [String: Any] = [
      "id": r.calendarItemIdentifier,
      "title": r.title ?? "",
      "notes": r.notes as Any,
      "completed": r.isCompleted,
      "completedAtMs": nil as Any?,
    ]
    if let dc = r.dueDateComponents,
       let date = Calendar.current.date(from: dc) {
      dict["dueMs"] = Int64(date.timeIntervalSince1970 * 1000)
    } else {
      dict["dueMs"] = nil as Any?
    }
    if r.isCompleted, let completed = r.completionDate {
      dict["completedAtMs"] = Int64(completed.timeIntervalSince1970 * 1000)
    }
    return dict
  }
}
