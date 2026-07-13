# Manual / smoke tests

These files are excluded from the default `flutter test` run
(see the top-level `dart_test.yaml`). They exercise real
platform-specific side effects (e.g. popping a Windows toast
notification) and are intended to be run by hand on the
developer's machine to verify the end-to-end path works after
touching platform-bridging code.

Run a specific one with, e.g.:

```
flutter test test/manual/smoke_windows_notification_test.dart
```

## Files

- `smoke_windows_notification_test.dart` — calls
  `NotificationService.show()` on Windows and asserts the
  call returns `true`. The OS toast should appear in the
  bottom-right of the screen.
- `smoke_windows_foreground_test.dart` — calls
  `NotificationService.setForegroundNotification(true, …)`
  on Windows, waits 500ms, then calls it with `active: false`
  to clear. The persistent timer badge toast should appear
  briefly, then disappear.
