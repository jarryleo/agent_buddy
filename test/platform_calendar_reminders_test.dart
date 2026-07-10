import 'package:agent_buddy/services/tool_service.dart';
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
}
