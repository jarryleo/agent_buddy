import EventKit
import Flutter
import Foundation

/// MethodChannel bridge for the iOS Reminders framework. Mirrors
/// the `agent_buddy/reminders` protocol. iOS gives us a real
/// to-do store via `EKReminder`, so unlike Android we don't
/// piggy-back on calendars.
public class RemindersBridge: NSObject, FlutterPlugin {
  public static let channelName = "agent_buddy/reminders"

  private let store = EKEventStore()

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
      Task { @MainActor in
        let granted = await self.ensurePermission()
        result(["granted": granted])
      }
    case "listCalendars":
      // iOS doesn't expose the "pick a calendar" picker flow that
      // Android needs. We still implement the method so the Dart
      // side gets a non-empty list back; the picker sheet is a
      // no-op on iOS because the system Reminders app handles
      // the default list. We return a single synthetic entry
      // pointing at the default reminders calendar.
      Task { @MainActor in
        let list = self.listWritableCalendars()
        result(list)
      }
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
      let includeCompleted = args["includeCompleted"] as? Bool ?? false
      let max = (args["max"] as? NSNumber)?.intValue ?? 50
      Task { @MainActor in
        do {
          let reminders = try await self.listReminders(
            includeCompleted: includeCompleted,
            max: max
          )
          result(reminders)
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    case "createReminder":
      Task { @MainActor in
        do {
          let r = try self.createReminder(args: args)
          result(r)
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    case "completeReminder":
      let id = args["id"] as? String ?? ""
      Task { @MainActor in
        do {
          let r = try self.completeReminder(id: id)
          result(r)
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    case "updateReminder":
      let id = args["id"] as? String ?? ""
      Task { @MainActor in
        do {
          let r = try self.updateReminder(id: id, args: args)
          result(r)
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    case "deleteReminder":
      let id = args["id"] as? String ?? ""
      Task { @MainActor in
        do {
          let ok = try self.deleteReminder(id: id)
          result(["ok": ok])
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Permission

  @MainActor
  private func ensurePermission() async -> Bool {
    if #available(iOS 17.0, *) {
      do {
        return try await store.requestFullAccessToReminders()
      } catch {
        return false
      }
    } else {
      return await withCheckedContinuation { cont in
        store.requestAccess(to: .reminder) { granted, _ in
          cont.resume(returning: granted)
        }
      }
    }
  }

  // MARK: - Calendar listing (iOS shim)

  @MainActor
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

  @MainActor
  private func listReminders(includeCompleted: Bool, max: Int) async throws -> [[String: Any]] {
    let cals = store.calendars(for: .reminder)
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil,
      ending: nil,
      calendars: cals
    )
    return try await withCheckedThrowingContinuation { cont in
      store.fetchReminders(matching: predicate) { ekReminders in
        let filtered = (ekReminders ?? []).filter { includeCompleted || !$0.isCompleted }
        let mapped = filtered.prefix(max).map { self.reminderToDict($0) }
        cont.resume(returning: Array(mapped))
      }
    }
  }

  @MainActor
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

  @MainActor
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

  @MainActor
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

  @MainActor
  private func deleteReminder(id: String) throws -> Bool {
    guard let calItem = store.calendarItem(withIdentifier: id) as? EKReminder else {
      return false
    }
    do {
      try store.remove(calItem, commit: true)
      return true
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to delete reminder: \(error.localizedDescription)"
      )
    }
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
