import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/pages/tools_tab.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stub that returns the requested English localization
/// string for any key. We only care about the keys the
/// `_toolUserName` / `_toolUserDescription` switches dispatch
/// to, so the stub's answer is read out of a flat map.
///
/// The localization codegen is loaded by the Flutter test
/// framework via `AppLocalizations.delegate.load(Locale('en'))`,
/// which produces the real `AppLocalizationsEn` object. To avoid
/// pulling that whole delegate into this test (it drags in the
/// material locale machinery), we construct a `_StubAppLocalizations`
/// that satisfies the parts of [AppLocalizations] we touch — only
/// the `toolName*` and `toolDesc*` getters.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    // Use the real delegate to materialise a fully-populated
    // English `AppLocalizations` so the test pins down the actual
    // ARB values, not a synthetic stub.
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('_toolUserName', () {
    test('returns a non-empty value for every built-in tool id', () {
      // Pin down that every tool the Settings tab can render
      // resolves to a localized name. If a new tool is added to
      // ToolRegistry without a corresponding case here, this
      // list will surface the regression (the new tool falls
      // through to default → '').
      const ids = <String>[
        'fetch_web',
        'current_time',
        'ask_user',
        'run_command',
        'get_environment',
        'calendar',
        'reminders',
        'notes',
        'tasks',
        'memory',
        'location',
        'download',
        'file',
        'search',
        'load_skill',
        'notification',
        'timer',
        'google_sheet',
        'call_mcp',
        'subagent',
        'edit_image',
      ];
      for (final id in ids) {
        expect(
          toolUserNameForTest(l10n, id),
          isNotEmpty,
          reason: 'missing _toolUserName case for "$id"',
        );
      }
    });

    test('returns the English label for edit_image', () {
      // Concrete check: pin down the exact translation rather
      // than just non-empty.
      expect(toolUserNameForTest(l10n, 'edit_image'), 'Edit Image');
    });

    test('returns an empty string for unknown ids', () {
      expect(toolUserNameForTest(l10n, 'no_such_tool'), '');
    });
  });

  group('_toolUserDescription', () {
    test('returns a non-empty value for every built-in tool id', () {
      const ids = <String>[
        'fetch_web',
        'current_time',
        'ask_user',
        'run_command',
        'get_environment',
        'calendar',
        'reminders',
        'notes',
        'tasks',
        'memory',
        'location',
        'download',
        'file',
        'search',
        'load_skill',
        'notification',
        'timer',
        'google_sheet',
        'call_mcp',
        'subagent',
        'edit_image',
      ];
      for (final id in ids) {
        expect(
          toolUserDescriptionForTest(l10n, id),
          isNotEmpty,
          reason: 'missing _toolUserDescription case for "$id"',
        );
      }
    });

    test('returns the English description for edit_image', () {
      // The user-facing description must be a localised string,
      // NOT the model's Chinese `ToolBase.description` (which
      // would fall through when the switch misses). The bug we
      // fixed was: edit_image fell through to default → '' →
      // ToolsTab fell back to the model-side Chinese
      // description, which is incorrect for an English UI.
      final desc = toolUserDescriptionForTest(l10n, 'edit_image');
      expect(desc, isNotEmpty);
      expect(desc, isNot(contains('编辑用户上传的图片')));
      expect(desc.toLowerCase(), contains('compress'));
      expect(desc.toLowerCase(), contains('crop'));
      expect(desc.toLowerCase(), contains('resize'));
      expect(desc.toLowerCase(), contains('rotate'));
      expect(desc.toLowerCase(), contains('convert'));
    });

    test('returns an empty string for unknown ids', () {
      expect(toolUserDescriptionForTest(l10n, 'no_such_tool'), '');
    });
  });
}