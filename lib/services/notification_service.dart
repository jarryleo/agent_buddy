import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Lightweight payload for a toast that should be shown to the user
/// via the in-app overlay (used on desktop / web where the OS-level
/// local-notification plugin is not available / useful).
class NotificationToast {
  const NotificationToast({
    required this.title,
    required this.body,
    this.tag = 'agent-buddy',
  });

  final String title;
  final String body;
  final String tag;
}

/// Singleton service that surfaces a message to the user.
///
/// - **Mobile (Android / iOS)**: posts a real OS-level local
///   notification via `flutter_local_notifications`. The
///   `initialize()` call wires up channels and asks for permission
///   on iOS / Android 13+.
/// - **Desktop / Web**: emits the payload on [toastStream] so the
///   in-app `NotificationHost` overlay (mounted at the root of the
///   app) can show a bottom-right toast. The plugin is never
///   imported on these platforms — `flutter_local_notifications` is
///   not needed for the in-app overlay path, and we don't want
///   mobile-only native code linked in by mistake on desktop.
///
/// Notifications are *only effective while the app is running* —
/// there is no scheduling, no native background workers, no
/// `zonedSchedule`. The "show immediately" path is the only API
/// the model and the timer service ever call.
class NotificationService {
  NotificationService();

  /// App-wide singleton. Construct a private instance for tests
  /// instead of going through the global.
  static final NotificationService instance = NotificationService();

  /// Public so tests / dev tooling can override the implementation
  /// before the app calls [initialize]. Internally a no-op for
  /// desktop / web (the overlay path doesn't need the plugin).
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _mobileSupported = false;

  /// Emits toast payloads for the in-app overlay (desktop / web).
  /// Listeners should dedupe / cap to avoid stacking.
  final StreamController<NotificationToast> _toastController =
      StreamController<NotificationToast>.broadcast();
  Stream<NotificationToast> get toastStream => _toastController.stream;

  /// Emits true when the active-timer foreground notification
  /// should be shown on mobile, false when it should be cleared.
  /// Listeners (a `Consumer` in the root widget tree) keep the
  /// ongoing notification in sync with the timer queue.
  final StreamController<bool> _foregroundController =
      StreamController<bool>.broadcast();
  Stream<bool> get foregroundStream => _foregroundController.stream;

  bool _isMobileNative() => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!_isMobileNative()) {
      // Desktop / web path: the overlay is enough.
      return;
    }
    try {
      const initSettings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // We don't ask for alert/badge/sound up-front — the
          // first show() call will surface a one-time permission
          // prompt on iOS / Android 13+. Keeps the cold-start
          // experience clean.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      await _plugin.initialize(initSettings);
      _mobileSupported = true;

      // Android 13+ runtime permission for posting notifications.
      // Asking on every launch is idempotent — if the user has
      // already answered, this is a no-op.
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();
    } catch (e) {
      // If the plugin is not linked (rare, e.g. a future platform
      // build without the Android/iOS shim), fall back to the
      // overlay-only path so the rest of the app still works.
      _mobileSupported = false;
    }
  }

  /// Posts a notification. The model's view: "show a toast /
  /// notification to the user with this title and body."
  ///
  /// - On mobile, posts a real OS notification.
  /// - On desktop / web, emits on [toastStream] for the in-app
  ///   overlay to pick up.
  /// Returns `true` on success, `false` if the platform-specific
  /// send failed (e.g. permission denied) — the model can decide
  /// whether to retry.
  Future<bool> show({
    required String title,
    required String body,
    int? notificationId,
  }) async {
    if (!_initialized) await initialize();
    if (title.trim().isEmpty && body.trim().isEmpty) return false;

    if (_isMobileNative() && _mobileSupported) {
      try {
        final id = notificationId ?? _nextId();
        final details = _detailsFor(title: title, body: body, ongoing: false);
        await _plugin.show(id, title, body, details);
        return true;
      } catch (_) {
        // Fall through to the overlay path so the user still sees
        // *something* even if the platform channel failed.
      }
    }
    // Desktop / web, or mobile fallback. Push a toast on the
    // in-app stream; the host widget shows it.
    if (!_toastController.isClosed) {
      _toastController.add(NotificationToast(title: title, body: body));
    }
    return true;
  }

  /// Shows or clears the persistent "you have N active timers"
  /// notification on mobile. The body carries the live count so
  /// the user can see at a glance how many are pending.
  Future<void> setForegroundNotification({
    required bool active,
    required String title,
    required String body,
  }) async {
    if (!_initialized) await initialize();
    if (!_foregroundController.isClosed) {
      _foregroundController.add(active);
    }
    if (!_isMobileNative() || !_mobileSupported) return;
    try {
      const fgId = 0x7E51;
      if (!active) {
        await _plugin.cancel(fgId);
        return;
      }
      final details = _detailsFor(title: title, body: body, ongoing: true);
      await _plugin.show(fgId, title, body, details);
    } catch (_) {
      // Best-effort: a failed foreground notification should never
      // break the timer / chat flow.
    }
  }

  NotificationDetails _detailsFor({
    required String title,
    required String body,
    required bool ongoing,
  }) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        ongoing ? 'agent_buddy_timers' : 'agent_buddy_messages',
        ongoing ? 'Active timers' : 'Messages',
        channelDescription: ongoing
            ? 'Persistent notification while one or more AI-set timers are pending'
            : 'Notifications the AI sends to you',
        importance: ongoing ? Importance.low : Importance.defaultImportance,
        priority: ongoing ? Priority.low : Priority.defaultPriority,
        ongoing: ongoing,
        autoCancel: !ongoing,
        onlyAlertOnce: ongoing,
        showWhen: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: !ongoing,
        threadIdentifier: ongoing
            ? 'agent_buddy_timers'
            : 'agent_buddy_messages',
      ),
    );
  }

  int _idCounter = 1;
  int _nextId() {
    // 1..N; the foreground service reserves 0x7E51 (32337). The
    // counter starts at 1 and wraps inside the int32 range — fine
    // for a single-session app.
    _idCounter = (_idCounter + 1) & 0x7FFFFFFF;
    if (_idCounter == 0x7E51) _idCounter = (_idCounter + 1) & 0x7FFFFFFF;
    return _idCounter;
  }

  Future<void> dispose() async {
    if (!_toastController.isClosed) await _toastController.close();
    if (!_foregroundController.isClosed) await _foregroundController.close();
  }
}
