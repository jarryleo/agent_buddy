// One-shot manual smoke test for the Windows notification path.
// Tagged `manual` — excluded from the default `flutter test`
// run (see top-level `dart_test.yaml`). Run explicitly:
//
//   flutter test test/manual/smoke_windows_notification_test.dart
//
// This is NOT a unit test — it actually invokes the
// `local_notifier` channel and pops a real Windows toast (or
// fails fast if the channel isn't available). Gated by
// `Platform.isWindows` so it skips on every other host.
import 'dart:io' show Platform;

import 'package:agent_buddy/services/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'smoke: show() on Windows surfaces a real toast',
    tags: ['manual'],
    () async {
      if (!Platform.isWindows) {
        // The plugin's native side is only registered on
        // Windows. On every other host, `show()` falls through
        // to the in-app toast — which is correct, but
        // uninteresting to smoke-test from CI.
        return;
      }
      final svc = NotificationService();
      await svc.initialize();
      final ok = await svc.show(
        title: 'Agent Buddy smoke test',
        body:
            'If you see this toast in the bottom-right of the screen, the local_notifier path works end-to-end.',
      );
      expect(ok, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
