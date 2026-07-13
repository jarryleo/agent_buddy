import EventKit
import Flutter
import Foundation

/// MethodChannel bridge for the iOS system calendar. Implements
/// the same 6-method protocol as the Android `CalendarBridge`:
/// ensurePermission / listEvents / getEvent / createEvent /
/// updateEvent / deleteEvent. On iOS 17+ we use the new Full
/// Access API; on older systems we fall back to the deprecated
/// `requestAccess(to:)` which still works but logs a warning.
///
/// Permission flow mirrors the Android side and `LocationBridge`:
/// every concurrent call is parked in a per-call pending map so
/// the user's tap on the system dialog resumes **all** of them —
/// not just the most recent one. This avoids the "tool call fails
/// before the user can answer" race when the model fires multiple
/// tool calls in quick succession.
public class CalendarBridge: NSObject, FlutterPlugin {
  public static let channelName = "agent_buddy/calendar"

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
      // Pure read; respond synchronously. The Dart side uses this to
      // decide whether to invoke any of the actions below.
      result(["granted": store.authorizationStatus(for: .event) == .fullAccess])
    case "listEvents":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "getEvent":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "createEvent":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "updateEvent":
      parkOrDispatch(call, result: result, method: call.method, args: args)
    case "deleteEvent":
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
    let status = store.authorizationStatus(for: .event)
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
          message: "Calendar permission permanently denied; open system settings to enable it",
          details: nil
        )
      )
      return
    }
    // .notDetermined: ask. Park the call. The system dialog's
    // completion is observed via the helper that polls the
    // authorization status (EKEventStore doesn't have a delegate
    // for requestFullAccessToEvents on iOS 17+).
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
    let callId = "cal-\(nextCallSeq)"
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

    // We are the first requester — fire the system dialog. EKEventStore
    // doesn't expose a delegate for this, so we wait for the async
    // request to complete and then dispatch all parked calls based
    // on the resulting authorization status.
    if #available(iOS 17.0, *) {
      Task { @MainActor in
        _ = try? await self.store.requestFullAccessToEvents()
        DispatchQueue.main.async { [weak self] in
          self?.resumeAllPending()
        }
      }
    } else {
      self.store.requestAccess(to: .event) { [weak self] _, _ in
        DispatchQueue.main.async {
          self?.resumeAllPending()
        }
      }
    }
  }

  private func resumeAllPending() {
    stateLock.lock()
    requestInFlight = false
    let status = self.store.authorizationStatus(for: .event)
    let snapshot = self.pendingByCallId
    stateLock.unlock()

    switch status {
    case .fullAccess:
      // User said yes — resume every parked call.
      for (cid, _) in snapshot {
        self.deliverResume(cid)
      }
    case .denied, .restricted:
      // User said no (and won't be asked again) — bubble
      // PERMANENTLY_DENIED up to every waiter.
      for (cid, _) in snapshot {
        self.deliverError(
          cid,
          code: "PERMANENTLY_DENIED",
          message: "Calendar permission permanently denied; open system settings to enable it"
        )
      }
    case .notDetermined:
      // The dialog was somehow dismissed without changing the
      // state. Surface a plain PERMISSION_DENIED so the AI can
      // tell the user something went wrong.
      for (cid, _) in snapshot {
        self.deliverError(
          cid,
          code: "PERMISSION_DENIED",
          message: "Calendar permission dialog was dismissed without a decision."
        )
      }
    @unknown default:
      for (cid, _) in snapshot {
        self.deliverError(
          cid,
          code: "PERMISSION_DENIED",
          message: "Calendar permission state is unknown."
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
    do {
      switch method {
      case "listEvents":
        let fromMs = (args["fromMs"] as? NSNumber)?.int64Value ?? 0
        let toMs = (args["toMs"] as? NSNumber)?.int64Value ?? 0
        let max = (args["max"] as? NSNumber)?.intValue ?? 50
        originalResult(self.listEvents(fromMs: fromMs, toMs: toMs, max: max))
      case "getEvent":
        let id = args["id"] as? String ?? ""
        originalResult(self.getEvent(id: id))
      case "createEvent":
        originalResult(try self.createEvent(args: args))
      case "updateEvent":
        let id = args["id"] as? String ?? ""
        let r = try self.updateEvent(id: id, args: args)
        originalResult(r as Any)
      case "deleteEvent":
        let id = args["id"] as? String ?? ""
        originalResult(["ok": self.deleteEvent(id: id)])
      default:
        originalResult(FlutterMethodNotImplemented)
      }
    } catch let err as BridgeError {
      originalResult(FlutterError(code: err.code, message: err.message, details: nil))
    } catch {
      originalResult(FlutterError(code: "BRIDGE_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  // MARK: - CRUD

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

  private func getEvent(id: String) -> [String: Any]? {
    guard let item = store.calendarItem(withIdentifier: id) as? EKEvent else {
      return nil
    }
    return eventToDict(item)
  }

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
