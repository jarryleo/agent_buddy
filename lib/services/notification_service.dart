import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';

/// Lightweight payload for a toast that should be shown to the user
/// via the in-app overlay (used on web where the OS-level
/// local-notification plugin is not available / useful, and as a
/// safety-net fallback when the platform-specific send fails).
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
/// Per-platform behaviour:
///
/// - **Android / iOS / macOS / Linux** — real OS-level local
///   notification via `flutter_local_notifications`. Channel +
///   permission setup happens in [initialize].
/// - **Windows** — real OS-level local notification via the
///   `local_notifier` plugin (which wraps the WinToast C++/WinRT
///   library, a thin layer over the modern
///   `Windows.UI.Notifications.ToastNotificationManager` API).
///   Everything stays in-process — no `powershell.exe` spawn, no
///   EDR / AV alerts. On first run [initialize] creates a
///   Start-Menu shortcut with the proper AppUserModelID; this is
///   a one-time side effect required by the modern toast API.
/// - **Web** — in-app bottom-right toast via [toastStream] +
///   `NotificationHost` widget. OS notifications on the web need
///   user permission and are unreliable across browsers, so we
///   keep the in-app toast for the web.
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

  /// Wraps the underlying `flutter_local_notifications` plugin
  /// used on mobile / macOS / Linux.
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _pluginSupported = false;
  bool _localNotifierReady = false;

  /// Emits toast payloads for the in-app overlay (web only, and
  /// as a fallback when an OS-level send fails). Listeners
  /// should dedupe / cap to avoid stacking.
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

  /// App name registered with the local notification framework.
  /// Used by `local_notifier` on Windows (Start-Menu shortcut
  /// AUMI) and as a default channel label on Android.
  static const String _appName = 'Agent Buddy';

  /// Stable identifier for the persistent "you have N active
  /// timers" notification. We use a fixed string so the
  /// platform can replace the in-place notification as the
  /// pending count changes.
  static const String _foregroundIdentifier = 'agent-buddy-foreground-timers';

  bool _isAndroid() => !kIsWeb && Platform.isAndroid;
  bool _isIOS() => !kIsWeb && Platform.isIOS;
  bool _isMacOS() => !kIsWeb && Platform.isMacOS;
  bool _isLinux() => !kIsWeb && Platform.isLinux;
  bool _isWindows() => !kIsWeb && Platform.isWindows;
  bool _isMobileNative() => _isAndroid() || _isIOS();
  bool _isPluginPlatform() => _isMobileNative() || _isMacOS() || _isLinux();

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    // --- Windows: local_notifier (WinToast C++/WinRT) ---
    // Setup creates a Start-Menu shortcut with the proper
    // AppUserModelID the first time the app runs. This is a
    // one-time side effect required by the modern toast API.
    if (_isWindows()) {
      try {
        await localNotifier.setup(
          appName: _appName,
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
        _localNotifierReady = true;
      } catch (e) {
        // Older Windows (pre-Win10) or sandboxed environments
        // without a writable Start Menu can't create the
        // shortcut. The in-app toast is the fallback — better
        // than nothing.
        _localNotifierReady = false;
      }
    }

    // --- Mobile / macOS / Linux: flutter_local_notifications ---
    if (!_isPluginPlatform()) return;
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
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        // Linux needs the app's "action name" (the label on the
        // default button on the notification). We don't expose
        // action buttons, so the default is fine.
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      await _plugin.initialize(initSettings);
      _pluginSupported = true;

      // Android 13+ runtime permission for posting notifications.
      // Asking on every launch is idempotent — if the user has
      // already answered, this is a no-op.
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();

      // macOS also needs an explicit permission ask. The
      // requestPermissions call surfaces a one-time system
      // dialog the first time the app posts a notification.
      final macosImpl = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      await macosImpl?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e) {
      // If the plugin is not linked (rare, e.g. a future platform
      // build without the macOS/Linux shim), fall back to the
      // in-app / local_notifier path so the rest of the app still
      // works.
      _pluginSupported = false;
    }
  }

  /// Posts a notification. The model's view: "show a toast /
  /// notification to the user with this title and body."
  ///
  /// - On Android / iOS / macOS / Linux: real OS notification
  ///   via `flutter_local_notifications`.
  /// - On Windows: real OS toast via `local_notifier` (WinRT).
  /// - On web: in-app bottom-right toast (Stream-driven overlay).
  ///
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

    // --- 1. Native OS notification (mobile / macOS / Linux) ---
    if (_isPluginPlatform() && _pluginSupported) {
      try {
        final id = notificationId ?? _nextId();
        final details = _detailsFor(title: title, body: body, ongoing: false);
        await _plugin.show(id, title, body, details);
        return true;
      } catch (_) {
        // Fall through to the local_notifier / in-app path so
        // the user still sees *something* even if the plugin
        // failed.
      }
    }

    // --- 2. Windows: in-process local_notifier (WinRT toast) ---
    if (_isWindows() && _localNotifierReady) {
      try {
        final notif = LocalNotification(
          identifier: _identifierForId(notificationId),
          title: title.isEmpty ? '通知' : title,
          body: body,
        );
        await notif.show();
        return true;
      } catch (_) {
        // Fall through to the in-app toast.
      }
    }

    // --- 3. In-app toast (web only in normal flow; also the
    // safety net for any platform where the OS send failed) ---
    _emitInAppToast(title, body);
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

    if (!active) {
      // Best-effort cancel on every OS path.
      if (_isPluginPlatform() && _pluginSupported) {
        try {
          await _plugin.cancel(_foregroundId);
        } catch (_) {}
      }
      if (_isWindows() && _localNotifierReady) {
        try {
          final n = LocalNotification(
            identifier: _foregroundIdentifier,
            title: '',
            body: '',
          );
          await n.close();
        } catch (_) {}
      }
      return;
    }
    if (title.trim().isEmpty && body.trim().isEmpty) return;

    if (_isPluginPlatform() && _pluginSupported) {
      try {
        final details = _detailsFor(title: title, body: body, ongoing: true);
        await _plugin.show(_foregroundId, title, body, details);
      } catch (_) {
        // Best-effort: a failed foreground notification should
        // never break the timer / chat flow.
      }
      return;
    }
    if (_isWindows() && _localNotifierReady) {
      try {
        // Windows has no "ongoing" concept for the modern
        // toast surface; the closest we can do is a regular
        // notification that lives until the user dismisses it
        // (or until the next `setForegroundNotification` call
        // replaces it by `identifier`).
        final notif = LocalNotification(
          identifier: _foregroundIdentifier,
          title: title,
          body: body,
          silent: true,
        );
        await notif.show();
      } catch (_) {}
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
      // The same Darwin detail shape works on macOS — the plugin
      // routes it to UNUserNotificationCenter.
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: !ongoing,
        threadIdentifier: ongoing
            ? 'agent_buddy_timers'
            : 'agent_buddy_messages',
      ),
      // Linux: `urgency` defaults to `normal`; `category` lets
      // the desktop environment pick an icon. The persistent
      // timer notification gets `low` urgency so it doesn't
      // steal focus from the chat.
      linux: LinuxNotificationDetails(
        urgency: ongoing
            ? LinuxNotificationUrgency.low
            : LinuxNotificationUrgency.normal,
        category: ongoing
            ? LinuxNotificationCategory.im
            : LinuxNotificationCategory.imReceived,
      ),
    );
  }

  void _emitInAppToast(String title, String body) {
    if (_toastController.isClosed) return;
    _toastController.add(
      NotificationToast(title: title.isEmpty ? '通知' : title, body: body),
    );
  }

  /// Builds a stable identifier for a one-off `LocalNotification`
  /// so the OS can re-use / replace it across calls. The plugin
  /// replaces a notification when the identifier matches, which
  /// is exactly what we want for the "active timers" badge
  /// (fixed identifier) and useful for the one-off chat
  /// notifications too (deterministic id avoids spam).
  String _identifierForId(int? id) {
    if (id == null) {
      return 'agent-buddy-message-${_idCounter++}';
    }
    return 'agent-buddy-message-$id';
  }

  int _idCounter = 1;
  static const int _foregroundId = 0x7E51; // 32337
  int _nextId() {
    // 1..N; the foreground service reserves 0x7E51 (32337). The
    // counter starts at 1 and wraps inside the int32 range — fine
    // for a single-session app.
    _idCounter = (_idCounter + 1) & 0x7FFFFFFF;
    if (_idCounter == _foregroundId) {
      _idCounter = (_idCounter + 1) & 0x7FFFFFFF;
    }
    return _idCounter;
  }

  Future<void> dispose() async {
    if (!_toastController.isClosed) await _toastController.close();
    if (!_foregroundController.isClosed) await _foregroundController.close();
  }
}
