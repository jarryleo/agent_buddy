// One-shot manual smoke test for the Windows foreground timer
// notification path. Tagged `manual` — excluded from the
// default `flutter test` run (see top-level `dart_test.yaml`).
// Run explicitly:
//
//   flutter test test/manual/smoke_windows_foreground_test.dart
import 'dart:io' show Platform;

import 'package:agent_buddy/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'smoke: setForegroundNotification(true) shows the badge toast',
    tags: ['manual'],
    () async {
      if (!Platform.isWindows) return;
      final svc = NotificationService();
      await svc.initialize();
      await svc.setForegroundNotification(
        active: true,
        title: '1 active timer: smoke test',
        body: 'drink water',
      );
      // Give the toast a moment to render, then clear it.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await svc.setForegroundNotification(active: false, title: '', body: '');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
