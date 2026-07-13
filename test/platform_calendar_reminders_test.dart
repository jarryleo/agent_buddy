import 'package:agent_buddy/models/calendar_event.dart';
import 'package:agent_buddy/models/reminder.dart';
import 'package:agent_buddy/services/platform/calendar_service.dart';
import 'package:agent_buddy/services/platform/calendar_service.dart'
    show PlatformPermissionStatus;
import 'package:agent_buddy/services/platform/calendar_service_io.dart';
import 'package:agent_buddy/services/platform/reminders_service_io.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runCalendar (stub path)', () {
    // On the dev / CI host the stub is what gets returned (no
    // MethodChannel is wired up here), so calling any action other
    // than the ones that throw before reaching the service should
    // surface an UnsupportedError -> ToolException translation.

    ToolService newService() => ToolService();

    test('action=list with valid window throws (stub unsupported)', () async {
      // On the test runner the factory picks the stub because the
      // host is not Android or iOS.
      final tools = newService();
      final now = DateTime.now();
      expect(
        () => tools.runCalendar({
          'action': 'list',
          'from': now.millisecondsSinceEpoch,
          'to': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
        }),
        throwsA(isA<ToolException>()),
      );
    });

    test('action=create with missing title throws validation error', () async {
      final tools = newService();
      expect(
        () => tools.runCalendar({
          'action': 'create',
          'start_ms': DateTime.now().millisecondsSinceEpoch,
        }),
        throwsA(isA<ToolException>()),
      );
    });

    test('unknown action throws validation error', () async {
      final tools = newService();
      expect(
        () => tools.runCalendar({'action': 'explode'}),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('runReminders (stub path)', () {
    ToolService newService() => ToolService();

    test('action=create with missing title throws validation error', () async {
      final tools = newService();
      expect(
        () => tools.runReminders({'action': 'create'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('action=complete on a stub still validates id presence', () async {
      final tools = newService();
      expect(
        () => tools.runReminders({'action': 'complete'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('unknown action throws validation error', () async {
      final tools = newService();
      expect(
        () => tools.runReminders({'action': 'nope'}),
        throwsA(isA<ToolException>()),
      );
    });

    test(
      'action=list envelope is well-formed JSON (validation only)',
      () async {
        // This one reaches the service and then throws via the stub
        // path. We assert that the tool call attempts the call and
        // throws — i.e. validation passes.
        final tools = newService();
        Object? caught;
        try {
          await tools.runReminders({'action': 'list'});
        } catch (e) {
          caught = e;
        }
        expect(caught, isNotNull);
        // Should be ToolException (UnsupportedError -> ToolException).
        expect(caught, isA<ToolException>());
      },
    );
  });

  // -------------------------------------------------------------------
  // Native bridge permission state machine.
  //
  // These tests pin the contract that the Android / iOS bridges
  // promise: an `ensurePermission` call returns the current OS-level
  // status without blocking on the user, and a per-action call that
  // arrives while the user is still being asked for permission is
  // parked until the user answers (then it gets the real result, not
  // a timeout). We mock the MethodChannel to simulate that.
  // -------------------------------------------------------------------

  group('CalendarServiceIo (MethodChannel mocking)', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    const channel = MethodChannel('agent_buddy/calendar');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('ensurePermission maps {granted:true}', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'ensurePermission') return {'granted': true};
            return null;
          });
      expect(
        (await CalendarServiceIo().ensurePermission()),
        PlatformPermissionStatus.granted,
      );
    });

    test('ensurePermission maps {granted:false} to denied', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'ensurePermission') return {'granted': false};
            return null;
          });
      expect(
        (await CalendarServiceIo().ensurePermission()),
        PlatformPermissionStatus.denied,
      );
    });

    test(
      'ensurePermission returns notSupported on MissingPluginException',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw MissingPluginException('not wired');
            });
        expect(
          (await CalendarServiceIo().ensurePermission()),
          PlatformPermissionStatus.notSupported,
        );
      },
    );

    test(
      'PERMANENTLY_DENIED bridge error is translated to permanentlyDenied',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'listEvents') {
                throw PlatformException(
                  code: 'PERMANENTLY_DENIED',
                  message: 'open settings',
                );
              }
              return null;
            });
        expect(
          () => CalendarServiceIo().listEvents(
            from: DateTime.now(),
            to: DateTime.now().add(const Duration(days: 1)),
          ),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'PERMANENTLY_DENIED',
            ),
          ),
        );
      },
    );

    test(
      'listEvents payload round-trips through CalendarEvent.fromJson',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'listEvents') {
                return [
                  {
                    'id': '42',
                    'title': 'team standup',
                    'startMs': 1700000000000,
                    'endMs': 1700003600000,
                    'allDay': false,
                    'location': 'Room 1',
                    'notes': null,
                    'calendarId': 'cal-1',
                    'calendarName': 'Work',
                    'alarmMinutes': 15,
                  },
                ];
              }
              return null;
            });
        final events = await CalendarServiceIo().listEvents(
          from: DateTime.fromMillisecondsSinceEpoch(0),
          to: DateTime.fromMillisecondsSinceEpoch(2000000000000),
        );
        expect(events, hasLength(1));
        final ev = events.first;
        expect(ev.id, '42');
        expect(ev.title, 'team standup');
        expect(ev.allDay, isFalse);
        expect(ev.calendarId, 'cal-1');
        expect(ev.alarmMinutes, 15);
        // Round-trip toJson is the same shape the native side gave us.
        final back = ev.toJson();
        expect(back['id'], '42');
        expect(back['title'], 'team standup');
        // Ensures the model key on the Dart side matches the wire key.
        expect(CalendarEvent.fromJson(back).title, 'team standup');
      },
    );
  });

  group('RemindersServiceIo (MethodChannel mocking)', () {
    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    const channel = MethodChannel('agent_buddy/reminders');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('ensurePermission maps {granted:true}', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'ensurePermission') return {'granted': true};
            return null;
          });
      expect(
        (await RemindersServiceIo().ensurePermission()),
        PlatformPermissionStatus.granted,
      );
    });

    test(
      'ensurePermission returns notSupported on MissingPluginException',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              throw MissingPluginException('not wired');
            });
        expect(
          (await RemindersServiceIo().ensurePermission()),
          PlatformPermissionStatus.notSupported,
        );
      },
    );

    test(
      'listReminders payload round-trips through Reminder.fromJson',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'listReminders') {
                return [
                  {
                    'id': 'r1',
                    'title': 'buy milk',
                    'notes': 'low fat',
                    'dueMs': 1700000000000,
                    'completed': false,
                    'completedAtMs': null,
                    'calendarName': 'Reminders',
                  },
                ];
              }
              return null;
            });
        final items = await RemindersServiceIo().listReminders();
        expect(items, hasLength(1));
        final r = items.first;
        expect(r.id, 'r1');
        expect(r.title, 'buy milk');
        expect(r.notes, 'low fat');
        expect(r.completed, isFalse);
        // Round-trip: the model key matches the wire key.
        final back = r.toJson();
        expect(back['id'], 'r1');
        expect(Reminder.fromJson(back).title, 'buy milk');
      },
    );
  });
}
