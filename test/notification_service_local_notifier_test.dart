// Tests for the Windows `local_notifier` integration path in
// `NotificationService`. The real plugin talks to native code
// (WinToast C++/WinRT) via the `local_notifier` method channel,
// so we install a fake handler on that channel and assert the
// call shape (method name, argument keys) without spawning any
// platform code.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:agent_buddy/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_notifier/local_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('local_notifier');

  late List<MethodCall> calls;
  late Completer<void> ready;

  setUp(() {
    calls = [];
    ready = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (!ready.isCompleted) ready.complete();
          calls.add(call);
          // Mirror the real plugin's return: setup returns a bool,
          // notify / close return null.
          if (call.method == 'setup') return true;
          return null;
        });
  });

  /// Installs a handler that *throws* on `setup`, so the service
  /// catches it and keeps `_localNotifierReady = false`. Used by
  /// the in-app-toast-fallback test.
  void installFailingHandler(Exception error) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'setup') throw error;
          return null;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // Skip the platform branch entirely on non-Windows hosts —
  // the Windows path uses `Platform.isWindows` as the gate, so
  // these tests are no-ops on macOS / Linux / Android. (We
  // still have a `localNotifier.notify` test below that uses
  // the public API on the host's real platform, but that
  // requires the plugin to be registered, which only happens
  // on Windows. So we gate the whole group on `isWindows`.)
  if (!Platform.isWindows) {
    test('local_notifier path is Windows-only (skip on this host)', () {
      // Sanity: the assertion would be `Platform.isWindows` is
      // true. We don't assert that here — we just acknowledge
      // the platform constraint.
      expect(Platform.isWindows, isFalse);
    });
    return;
  }

  group('NotificationService local_notifier (Windows)', () {
    test('initialize calls setup with appName + shortcutPolicy', () async {
      final svc = NotificationService();
      await svc.initialize();
      // Wait for the mock channel to see the call.
      await ready.future;
      expect(calls, isNotEmpty);
      final setup = calls.firstWhere((c) => c.method == 'setup');
      expect(setup.arguments, isA<Map>());
      final args = (setup.arguments as Map).cast<String, dynamic>();
      expect(args['appName'], 'Agent Buddy');
      // The Dart enum value's `.name` is the value the
      // plugin expects.
      expect(args['shortcutPolicy'], ShortcutPolicy.requireCreate.name);
    });

    test(
      'show() posts a LocalNotification with title + body on Windows',
      () async {
        final svc = NotificationService();
        await svc.initialize();
        // Drain the `setup` call so we can scope the
        // assertion to the post-init traffic only.
        await ready.future;
        calls.clear();

        final ok = await svc.show(title: 'Hello', body: 'World');
        expect(ok, isTrue);
        // Exactly one `notify` call should have gone out on
        // the local_notifier channel.
        final notifyCalls = calls.where((c) => c.method == 'notify').toList();
        expect(notifyCalls, hasLength(1));
        final args = (notifyCalls.first.arguments as Map)
            .cast<String, dynamic>();
        expect(args['title'], 'Hello');
        expect(args['body'], 'World');
        expect(args['identifier'], isA<String>());
        expect(args['appName'], 'Agent Buddy');
      },
    );

    test('show() falls back to in-app toast on Windows when '
        'local_notifier setup throws (sandboxed env / older Win)', () async {
      // Replace the default handler with one that throws on
      // `setup`, mimicking an environment where the WinToast
      // native side can't be initialised (sandboxed Start
      // Menu, older Windows, etc.). The service should
      // catch, keep `_localNotifierReady = false`, and emit
      // the in-app toast.
      installFailingHandler(
        PlatformException(code: 'INIT_FAILED', message: 'nope'),
      );
      final svc = NotificationService();
      final toasts = <NotificationToast>[];
      final sub = svc.toastStream.listen(toasts.add);
      final ok = await svc.show(title: 'Fallback', body: 'body');
      expect(ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The local_notifier path was skipped — no `notify`
      // call should have been issued.
      expect(calls.where((c) => c.method == 'notify'), isEmpty);
      // The in-app toast was emitted.
      expect(toasts, hasLength(1));
      expect(toasts.first.title, 'Fallback');
      expect(toasts.first.body, 'body');
      await sub.cancel();
    });

    test('setForegroundNotification(true) posts a silent LocalNotification '
        'with the foreground identifier', () async {
      final svc = NotificationService();
      await svc.initialize();
      await ready.future;
      calls.clear();
      await svc.setForegroundNotification(
        active: true,
        title: '2 active timers',
        body: 'drink water',
      );
      final notifyCalls = calls.where((c) => c.method == 'notify').toList();
      expect(notifyCalls, hasLength(1));
      final args = (notifyCalls.first.arguments as Map).cast<String, dynamic>();
      expect(args['identifier'], 'agent-buddy-foreground-timers');
      expect(args['title'], '2 active timers');
      expect(args['body'], 'drink water');
      expect(args['silent'], isTrue);
    });

    test('setForegroundNotification(false) sends a close call with the '
        'foreground identifier', () async {
      final svc = NotificationService();
      await svc.initialize();
      await ready.future;
      calls.clear();
      await svc.setForegroundNotification(
        active: false,
        title: 'unused',
        body: 'unused',
      );
      final closeCalls = calls.where((c) => c.method == 'close').toList();
      expect(closeCalls, hasLength(1));
      final args = (closeCalls.first.arguments as Map).cast<String, dynamic>();
      expect(args['identifier'], 'agent-buddy-foreground-timers');
    });

    test('show() preserves a caller-supplied notificationId in the '
        'local_notifier identifier so it can replace a prior toast', () async {
      final svc = NotificationService();
      await svc.initialize();
      await ready.future;
      calls.clear();

      await svc.show(title: 'A', body: 'a', notificationId: 42);
      await svc.show(title: 'B', body: 'b', notificationId: 42);
      final notifyCalls = calls.where((c) => c.method == 'notify').toList();
      expect(notifyCalls, hasLength(2));
      // Same id → same identifier string. The OS re-uses
      // the toast slot so the new body replaces the old
      // one instead of stacking.
      final id1 = (notifyCalls[0].arguments as Map)['identifier'] as String;
      final id2 = (notifyCalls[1].arguments as Map)['identifier'] as String;
      expect(id1, id2);
      expect(id1, 'agent-buddy-message-42');
    });
  });
}
