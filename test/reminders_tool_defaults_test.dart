import 'package:agent_buddy/services/tools/reminders_tool.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
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

    test('isEnabledByDefault is false on every platform where the tool '
        'is supported, so the fresh-install and existing-install '
        'seeding paths in SettingsProvider both skip it', () {
      // We can't easily flip isMobile from a unit test, but the
      // flag is constant and platform-independent — verifying
      // once is enough.
      expect(RemindersTool().isEnabledByDefault, isFalse);
    });
  });

  group('ToolBase.isEnabledByDefault default', () {
    test('defaults to true so the existing tools (fetch_web, current_time, '
        '...) keep their opt-out behavior — only `reminders` and '
        '`google_sheet` (both need one-time setup) opt in explicitly', () {
      // Walk the registry and assert every tool's default — except
      // `reminders` and `google_sheet`, which both override to
      // false because their first use requires a picker / OAuth
      // flow that the user has to walk through. A future tool
      // that needs the same flow should join this exception list,
      // not flip the default.
      const exceptionIds = {'reminders', 'google_sheet'};
      for (final tool in ToolRegistry.all) {
        if (exceptionIds.contains(tool.id)) {
          expect(
            tool.isEnabledByDefault,
            isFalse,
            reason: '${tool.id} should default to off',
          );
        } else {
          expect(
            tool.isEnabledByDefault,
            isTrue,
            reason: '${tool.id} should default to on',
          );
        }
      }
    });
  });
}
