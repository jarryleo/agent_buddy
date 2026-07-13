import 'dart:io';

import 'package:agent_buddy/models/skill.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late StorageService storage;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_builtin_skills_test_',
    );
    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  group('SettingsProvider load() — built-in skills', () {
    test('fresh install seeds every BuiltinSkill and enables it', () async {
      final settings = SettingsProvider(storage);
      await settings.load();

      final ids = settings.skills.map((s) => s.id).toSet();
      for (final builtin in BuiltinSkills.all) {
        expect(
          ids,
          contains(builtin.id),
          reason: 'missing built-in skill ${builtin.id}',
        );
      }

      // Both built-ins should be active out of the box.
      final activeIds = settings.activeSkillIds;
      for (final builtin in BuiltinSkills.all) {
        expect(activeIds, contains(builtin.id));
      }

      // And they should report isBuiltin == true.
      for (final s in settings.skills.where((s) => s.isBuiltin)) {
        expect(s.isBuiltin, isTrue);
        expect(s.enabled, isTrue);
      }
    });

    test('content matches the BuiltinSkill definitions', () async {
      final settings = SettingsProvider(storage);
      await settings.load();

      for (final builtin in BuiltinSkills.all) {
        final stored = settings.skills.firstWhere((s) => s.id == builtin.id);
        expect(stored.name, builtin.name);
        expect(stored.description, builtin.description);
        expect(stored.content, builtin.content);
      }
    });

    test('user-added skills are preserved across load()', () async {
      // Pre-populate storage with a user skill and a missing built-in.
      final userSkill = Skill(
        id: 'user-uuid-1',
        name: '我的笔记',
        description: '我自己加的',
        content: '...',
      );
      final persisted = [userSkill.toRawJson()];
      SharedPreferences.setMockInitialValues({
        'skills': persisted,
        'active_skill_ids': [userSkill.id],
      });
      // Re-init storage with the seeded prefs.
      storage = StorageService();
      await storage.init();

      final settings = SettingsProvider(storage);
      await settings.load();

      // User skill survives.
      expect(settings.skills.where((s) => s.id == userSkill.id).length, 1);
      // And every built-in gets back-filled.
      for (final builtin in BuiltinSkills.all) {
        expect(settings.skills.map((s) => s.id).toSet(), contains(builtin.id));
        expect(settings.activeSkillIds, contains(builtin.id));
      }
    });

    test('a user can no longer delete a built-in via deleteSkill', () async {
      final settings = SettingsProvider(storage);
      await settings.load();

      final builtinId = BuiltinSkills.all.first.id;
      expect(settings.skills.any((s) => s.id == builtinId), isTrue);

      await settings.deleteSkill(builtinId);

      // Still there.
      expect(settings.skills.any((s) => s.id == builtinId), isTrue);
      expect(settings.activeSkillIds, contains(builtinId));
    });

    test('toggling a built-in off sticks across load()', () async {
      // First load: both built-ins are seeded + active.
      final settings = SettingsProvider(storage);
      await settings.load();
      final builtinId = BuiltinSkills.all.first.id;

      await settings.toggleSkill(builtinId, false);
      expect(settings.activeSkillIds.contains(builtinId), isFalse);

      // Second load should NOT silently re-enable it.
      final settings2 = SettingsProvider(storage);
      await settings2.load();
      expect(settings2.activeSkillIds.contains(builtinId), isFalse);
      expect(
        settings2.skills.firstWhere((s) => s.id == builtinId).enabled,
        isFalse,
      );
    });

    test('user edits to a built-in persist across load()', () async {
      final settings = SettingsProvider(storage);
      await settings.load();
      final builtinId = BuiltinSkills.all.first.id;

      final original = settings.skills.firstWhere((s) => s.id == builtinId);
      await settings.updateSkill(
        original.copyWith(name: 'Custom name', content: 'My own content'),
      );

      final settings2 = SettingsProvider(storage);
      await settings2.load();
      final reloaded = settings2.skills.firstWhere((s) => s.id == builtinId);
      expect(reloaded.name, 'Custom name');
      expect(reloaded.content, 'My own content');
      // Still reported as built-in (id is preserved).
      expect(reloaded.isBuiltin, isTrue);
    });
  });
}
