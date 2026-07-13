import 'dart:io';

import 'package:agent_buddy/models/tool.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `SettingsProvider.load()` mutates persistent state, so each test
/// must reset both the SharedPreferences mock and the Hive temp
/// directory. The provider reaches into both via
/// `StorageService.init()` (which opens the chat-session box).
void main() {
  late Directory tempDir;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_settings_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  Future<SettingsProvider> loadProvider() async {
    final storage = StorageService();
    await storage.init();
    final p = SettingsProvider(storage);
    await p.load();
    return p;
  }

  group('SettingsProvider.load() — reminders default off', () {
    final remindersSupported = ToolRegistry.byId('reminders')!
        .isSupportedOnCurrentPlatform;

    test(
      'fresh install: reminders is in the tool list (so the user '
      'can toggle it on) but NOT in activeToolIds (so the model '
      'won\'t invoke it before the user has picked a todo calendar)',
      () async {
        final p = await loadProvider();
        if (!remindersSupported) {
          // On the dev host (Windows / Linux / macOS / web) the
          // reminders tool is a stub and not in the tool list at
          // all. Nothing to assert.
          return;
        }
        final reminders = p.tools.firstWhere((t) => t.id == 'reminders');
        expect(reminders, isNotNull);
        expect(reminders.enabled, isFalse,
            reason: 'tool card switch should start off');
        expect(p.activeToolIds.contains('reminders'), isFalse,
            reason: 'model should not see reminders before setup');
      },
    );

    test(
      'fresh install: every other builtin tool IS in activeToolIds '
      'and enabled (regression guard for the default-on behavior)',
      () async {
        final p = await loadProvider();
        for (final t in ToolRegistry.all) {
          if (t.id == 'reminders') continue;
          if (!t.isSupportedOnCurrentPlatform) continue;
          expect(p.activeToolIds.contains(t.id), isTrue,
              reason: '${t.id} should default to active');
          final card = p.tools.firstWhere((card) => card.id == t.id);
          expect(card.enabled, isTrue,
              reason: '${t.id} card switch should default to on');
        }
      },
    );

    test(
      'existing install: a stored activeToolIds that does NOT '
      'include `reminders` is left alone (the backfill only adds '
      'tools that default to on)',
      () async {
        if (!remindersSupported) return;
        // Seed a previous-install state: a tool list with
        // everything enabled and an activeToolIds set that
        // intentionally excludes `reminders`.
        final preExisting = [
          for (final t in ToolRegistry.all)
            if (t.isSupportedOnCurrentPlatform)
              AgentTool(
                id: t.id,
                name: t.name,
                description: t.description,
                enabled: true,
              ),
        ];
        final stored = preExisting.map((t) => t.toRawJson()).toList();
        final activeIds = [
          for (final t in ToolRegistry.all)
            if (t.isSupportedOnCurrentPlatform && t.id != 'reminders')
              t.id,
        ];
        SharedPreferences.setMockInitialValues({
          'tools': stored,
          'active_tool_ids': activeIds,
        });

        final p = await loadProvider();
        expect(p.activeToolIds.contains('reminders'), isFalse,
            reason: 'reminders must NOT be back-filled into activeToolIds');
        // The other tools should still be there.
        for (final t in ToolRegistry.all) {
          if (t.id == 'reminders') continue;
          if (!t.isSupportedOnCurrentPlatform) continue;
          expect(p.activeToolIds.contains(t.id), isTrue,
              reason: '${t.id} should still be active');
        }
      },
    );

    test(
      'fresh install: the persisted active_tool_ids key actually '
      'contains every supported builtin EXCEPT reminders, so a '
      'restart keeps the same default-off state',
      () async {
        await loadProvider();
        final prefs = await SharedPreferences.getInstance();
        final stored = prefs.getStringList('active_tool_ids') ?? const [];
        if (remindersSupported) {
          expect(stored.contains('reminders'), isFalse,
              reason: 'persisted state should not enable reminders');
        }
        for (final t in ToolRegistry.all) {
          if (t.id == 'reminders') continue;
          if (!t.isSupportedOnCurrentPlatform) continue;
          expect(stored.contains(t.id), isTrue,
              reason: '${t.id} should be persisted as active');
        }
      },
    );
  });
}
