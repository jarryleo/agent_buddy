import 'package:agent_buddy/services/tools/reminders_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemindersTool defaults', () {
    test('id is the wire name the Dart side dispatches on', () {
      expect(RemindersTool().id, 'reminders');
    });

    test('isEnabledByDefault is false so the picker is the user\'s '
        'first interaction with the tool (not a silent NO_TODO_CALENDAR '
        'failure on the first model invocation)', () {
      expect(RemindersTool().isEnabledByDefault, isFalse);
    });
  });
}
