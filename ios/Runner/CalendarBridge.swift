import EventKit
import Flutter
import Foundation

/// MethodChannel bridge for the iOS system calendar. Implements
/// the same 6-method protocol as the Android `CalendarBridge`:
/// ensurePermission / listEvents / getEvent / createEvent /
/// updateEvent / deleteEvent. On iOS 17+ we use the new Full
/// Access API; on older systems we fall back to the deprecated
/// `requestAccess(to:)` which still works but logs a warning.
public class CalendarBridge: NSObject, FlutterPlugin {
  public static let channelName = "agent_buddy/calendar"

  private let store = EKEventStore()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = CalendarBridge()
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
        let status = await self.ensurePermission()
        result(["granted": status == .granted])
      }
    case "listEvents":
      let fromMs = (args["fromMs"] as? NSNumber)?.int64Value ?? 0
      let toMs = (args["toMs"] as? NSNumber)?.int64Value ?? 0
      let max = (args["max"] as? NSNumber)?.intIntValue ?? 50
      Task { @MainActor in
        let events = self.listEvents(fromMs: fromMs, toMs: toMs, max: max)
        result(events)
      }
    case "getEvent":
      let id = args["id"] as? String ?? ""
      Task { @MainActor in
        result(self.getEvent(id: id))
      }
    case "createEvent":
      Task { @MainActor in
        do {
          let ev = try self.createEvent(args: args)
          result(ev)
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    case "updateEvent":
      let id = args["id"] as? String ?? ""
      Task { @MainActor in
        do {
          let ev = try self.updateEvent(id: id, args: args)
          result(ev)
        } catch let err as BridgeError {
          result(FlutterError(code: err.code, message: err.message, details: nil))
        } catch {
          result(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
        }
      }
    case "deleteEvent":
      let id = args["id"] as? String ?? ""
      Task { @MainActor in
        let ok = self.deleteEvent(id: id)
        result(["ok": ok])
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Permission

  private enum PermissionOutcome { case granted, denied, notSupported }

  @MainActor
  private func ensurePermission() async -> PermissionOutcome {
    if #available(iOS 17.0, *) {
      do {
        return try await store.requestFullAccessToEvents()
          ? .granted
          : .denied
      } catch {
        return .denied
      }
    } else {
      return await withCheckedContinuation { cont in
        store.requestAccess(to: .event) { granted, _ in
          cont.resume(returning: granted ? .granted : .denied)
        }
      }
    }
  }

  // MARK: - CRUD

  @MainActor
  private func listEvents(fromMs: Int64, toMs: Int64, max: Int) -> [[String: Any]] {
    let from = Date(timeIntervalSince1970: TimeInterval(fromMs) / 1000.0)
    let to = Date(timeIntervalSince1970: TimeInterval(toMs) / 1000.0)
    let cals = store.calendars(for: .event)
    let predicate = store.predicateForEvents(
      withStart: from,
      end: to,
      calendars: cals
    )
    let events = store.events(matching: predicate)
    return events.prefix(max).map { eventToDict($0) }
  }

  @MainActor
  private func getEvent(id: String) -> [String: Any]? {
    guard let item = store.calendarItem(withIdentifier: id) as? EKEvent else {
      return nil
    }
    return eventToDict(item)
  }

  @MainActor
  private func createEvent(args: [String: Any]) throws -> [String: Any] {
    let title = args["title"] as? String ?? ""
    if title.isEmpty {
      throw BridgeError(code: "INVALID_ARGUMENT", message: "title required")
    }
    let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
    if startMs == 0 {
      throw BridgeError(code: "INVALID_ARGUMENT", message: "startMs required")
    }
    let endMs = (args["end_ms"] as? NSNumber)?.int64Value
      ?? (args["endMs"] as? NSNumber)?.int64Value
    let notes = args["notes"] as? String
    let location = args["location"] as? String
    let alarmMinutes = (args["alarm_minutes"] as? NSNumber)?.intValue
      ?? (args["alarmMinutes"] as? NSNumber)?.intValue

    let event = EKEvent(eventStore: store)
    event.title = title
    event.startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0)
    if let endMs = endMs {
      event.endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)
    } else {
      event.endDate = event.startDate.addingTimeInterval(60 * 60)
    }
    event.notes = notes
    event.location = location
    event.calendar = store.defaultCalendarForNewEvents
    if let alarmMinutes = alarmMinutes {
      let alarm = EKAlarm(relativeOffset: TimeInterval(-alarmMinutes * 60))
      event.addAlarm(alarm)
    }
    do {
      try store.save(event, span: .thisEvent, commit: true)
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to save event: \(error.localizedDescription)"
      )
    }
    return eventToDict(event)
  }

  @MainActor
  private func updateEvent(id: String, args: [String: Any]) throws -> [String: Any]? {
    guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
      return nil
    }
    if let title = args["title"] as? String { event.title = title }
    if let startMs = (args["startMs"] as? NSNumber)?.int64Value {
      event.startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0)
    }
    if let endMs = (args["end_ms"] as? NSNumber)?.int64Value {
      event.endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)
    } else if let endMs = (args["endMs"] as? NSNumber)?.int64Value {
      event.endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)
    }
    if let notes = args["notes"] as? String { event.notes = notes }
    if let location = args["location"] as? String { event.location = location }
    if let alarmMinutes = (args["alarm_minutes"] as? NSNumber)?.intValue {
      event.alarms = [EKAlarm(relativeOffset: TimeInterval(-alarmMinutes * 60))]
    } else if let alarmMinutes = (args["alarmMinutes"] as? NSNumber)?.intValue {
      event.alarms = [EKAlarm(relativeOffset: TimeInterval(-alarmMinutes * 60))]
    }
    do {
      try store.save(event, span: .thisEvent, commit: true)
    } catch {
      throw BridgeError(
        code: "BRIDGE_ERROR",
        message: "failed to update event: \(error.localizedDescription)"
      )
    }
    return eventToDict(event)
  }

  @MainActor
  private func deleteEvent(id: String) -> Bool {
    guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
      return false
    }
    do {
      try store.remove(event, span: .thisEvent, commit: true)
      return true
    } catch {
      return false
    }
  }

  // MARK: - Mapping

  private func eventToDict(_ event: EKEvent) -> [String: Any] {
    var dict: [String: Any] = [
      "id": event.eventIdentifier ?? "",
      "title": event.title ?? "",
      "startMs": Int64(event.startDate.timeIntervalSince1970 * 1000),
      "allDay": event.isAllDay,
      "location": event.location as Any,
      "notes": event.notes as Any,
      "calendarId": event.calendar.calendarIdentifier,
      "calendarName": event.calendar.title,
      "alarmMinutes": nil as Any?,
    ]
    if let end = event.endDate {
      dict["endMs"] = Int64(end.timeIntervalSince1970 * 1000)
    } else {
      dict["endMs"] = nil as Any?
    }
    if let alarm = event.alarms?.first {
      let minutes = Int(-alarm.relativeOffset / 60)
      dict["alarmMinutes"] = minutes
    }
    return dict
  }
}

struct BridgeError: Error {
  let code: String
  let message: String
}
