import CoreLocation
import Flutter
import Foundation

/// MethodChannel bridge for the iOS CoreLocation framework. The
/// model only needs a single-shot coarse fix ("what's the weather
/// here" / "what's my timezone"), so we use `requestLocation()`
/// rather than continuous updates. We don't ship a reverse-geocode
/// here because iOS would force us to depend on CLGeocoder (works
/// but adds latency) — `city / region / country` come back as
/// `null` and the model can read the timezone from the system
/// `TimeZone.current.identifier` instead.
///
/// Both methods (`ensurePermission` and `getCurrentLocation`) drive
/// the system prompt on the first call: if authorization is
/// `.notDetermined` we ask; if the user has already denied we
/// surface `PERMISSION_DENIED` so the AI can show a hint. Pending
/// callbacks are tracked per call by id so concurrent requests
/// don't trample each other.
public class LocationBridge: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  public static let channelName = "agent_buddy/location"

  private var manager: CLLocationManager?
  private var pendingByCallId: [String: Pending] = [:]
  private var nextCallSeq: Int = 0
  private let stateLock = NSLock()

  private struct Pending {
    let result: FlutterResult
    let kind: Kind
    let timeoutWork: DispatchWorkItem
    let fired: NSLock // guards a single-fire Bool below
    var delivered: Bool
  }
  private enum Kind {
    case ensure
    case fetch(timeoutMs: Int)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = LocationBridge()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "ensurePermission":
      ensurePermission(result: result)
    case "getCurrentLocation":
      let args = call.arguments as? [String: Any] ?? [:]
      let timeoutMs = (args["timeoutMs"] as? NSNumber)?.intValue ?? 10_000
      fetchLocation(result: result, timeoutMs: timeoutMs)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Permission

  private func ensurePermission(result: @escaping FlutterResult) {
    let m = ensureManager()
    let status = m.authorizationStatus
    switch status {
    case .authorizedAlways, .authorizedWhenInUse:
      result([
        "granted": true,
        "status": "granted",
      ])
    case .notDetermined:
      // Ask the OS. We *must* come back through the delegate and
      // deliver the result there, so stash it in the pending map.
      let callId = registerPending(result, kind: .ensure(timeoutMs: 0))
      m.requestWhenInUseAuthorization()
      // requestWhenInUseAuthorization has no completion handler on
      // its own; the result lands in
      // locationManagerDidChangeAuthorization.
    case .denied, .restricted:
      result([
        "granted": false,
        "status": "permanently_denied",
      ])
    @unknown default:
      result([
        "granted": false,
        "status": "denied",
      ])
    }
  }

  // MARK: - Fetch

  private func fetchLocation(result: @escaping FlutterResult, timeoutMs: Int) {
    let m = ensureManager()
    let status = m.authorizationStatus
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      let callId = registerPending(result, kind: .fetch(timeoutMs: timeoutMs))
      armTimeout(callId: callId, timeoutMs: timeoutMs)
      m.requestLocation()
    case .notDetermined:
      // Ask first; once the user answers, the delegate decides
      // whether to fetch or to bubble PERMISSION_DENIED up.
      let callId = registerPending(result, kind: .fetch(timeoutMs: timeoutMs))
      armTimeout(callId: callId, timeoutMs: timeoutMs)
      m.requestWhenInUseAuthorization()
    case .denied, .restricted:
      result(
        FlutterError(
          code: "PERMISSION_DENIED",
          message: "Location permission was denied; please grant it in system settings.",
          details: nil
        )
      )
    @unknown default:
      result(
        FlutterError(
          code: "PERMISSION_DENIED",
          message: "Location permission state is unknown.",
          details: nil
        )
      )
    }
  }

  // MARK: - Pending tracking

  @discardableResult
  private func registerPending(_ result: @escaping FlutterResult, kind: Kind) -> String {
    stateLock.lock()
    nextCallSeq += 1
    let callId = "loc-\(nextCallSeq)"
    let fireLock = NSLock()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.deliver(
        callId: callId,
        success: nil,
        error: FlutterError(
          code: "LOCATION_TIMEOUT",
          message: "location request timed out",
          details: nil
        )
      )
    }
    pendingByCallId[callId] = Pending(
      result: result,
      kind: kind,
      timeoutWork: work,
      fired: fireLock,
      delivered: false,
    )
    stateLock.unlock()
    return callId
  }

  private func armTimeout(callId: String, timeoutMs: Int) {
    stateLock.lock()
    guard let p = pendingByCallId[callId] else {
      stateLock.unlock()
      return
    }
    stateLock.unlock()
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(timeoutMs),
      execute: p.timeoutWork
    )
  }

  private func deliver(callId: String, success: Any?, error: FlutterError?) {
    stateLock.lock()
    guard var p = pendingByCallId[callId] else {
      stateLock.unlock()
      return
    }
    p.fired.lock()
    if p.delivered {
      p.fired.unlock()
      stateLock.unlock()
      return
    }
    p.delivered = true
    p.fired.unlock()
    pendingByCallId.removeValue(forKey: callId)
    stateLock.unlock()
    p.timeoutWork.cancel()
    if let s = success {
      p.result(s)
    } else if let e = error {
      p.result(e)
    } else {
      p.result(
        FlutterError(
          code: "LOCATION_UNAVAILABLE",
          message: "no result delivered",
          details: nil
        )
      )
    }
  }

  private func ensureManager() -> CLLocationManager {
    if let m = manager { return m }
    let m = CLLocationManager()
    m.delegate = self
    m.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager = m
    return m
  }

  // MARK: - CLLocationManagerDelegate

  public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      // For every pending .ensure call, deliver granted. For every
      // pending .fetch call, fire off a requestLocation.
      stateLock.lock()
      let snapshot = pendingByCallId
      stateLock.unlock()
      for (callId, p) in snapshot {
        switch p.kind {
        case .ensure:
          deliver(
            callId: callId,
            success: ["granted": true, "status": "granted"],
            error: nil,
          )
        case .fetch:
          // Re-arm: this call already has its own timeout running
          // (started when we queued the call), so just ask for a
          // fix; the existing timeout will catch a real failure.
          manager.requestLocation()
        }
      }
    case .denied, .restricted:
      // User refused at the system prompt. Bubble PERMISSION_DENIED
      // up to every waiter.
      let snapshot = stateLock.withLock { pendingByCallId }
      for (callId, _) in snapshot {
        deliver(
          callId: callId,
          success: nil,
          error: FlutterError(
            code: "PERMISSION_DENIED",
            message: "Location permission was denied; please grant it in system settings.",
            details: nil
          )
        )
      }
    case .notDetermined:
      // Race: iOS sometimes re-enters this state. Just wait.
      break
    @unknown default:
      break
    }
  }

  public func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let loc = locations.last else { return }
    let tz = TimeZone.current.identifier
    let payload: [String: Any] = [
      "latitude": loc.coordinate.latitude,
      "longitude": loc.coordinate.longitude,
      "accuracyMeters": loc.horizontalAccuracy,
      "city": NSNull(),
      "region": NSNull(),
      "country": NSNull(),
      "countryCode": NSNull(),
      "timezone": tz,
      "source": "gps",
      "fetchedAtMs": Int64(Date().timeIntervalSince1970 * 1000),
    ]
    // Route the fix to the *first* pending .fetch call. If multiple
    // fetches are in flight they all get the same fix — that's
    // fine, CLLocationManager is single-fix-per-request by design.
    let snapshot = stateLock.withLock { pendingByCallId }
    for (callId, p) in snapshot {
      if case .fetch = p.kind {
        deliver(callId: callId, success: payload, error: nil)
        break
      }
    }
  }

  public func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    let code: String
    if let cl = error as? CLError {
      switch cl.code {
      case .denied:
        code = "PERMISSION_DENIED"
      default:
        code = "LOCATION_UNAVAILABLE"
      }
    } else {
      code = "LOCATION_UNAVAILABLE"
    }
    let snapshot = stateLock.withLock { pendingByCallId }
    for (callId, _) in snapshot {
      deliver(
        callId: callId,
        success: nil,
        error: FlutterError(
          code: code,
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
