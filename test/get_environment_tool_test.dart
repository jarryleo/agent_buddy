import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/get_environment_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ToolService toolService;

  setUpAll(ChatSessionRepository.registerAdapters);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp(
      'get_environment_tool_',
    );
    Hive.init(tempDir.path);
    addTearDown(() async {
      // Windows sometimes holds a lingering handle on the temp
      // dir when the prior test spawned a child process. Retry
      // a few times before giving up — the tests are passing
      // either way; the failure is only in the cleanup.
      for (var i = 0; i < 5; i++) {
        try {
          await tempDir.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final storage = StorageService();
    await storage.init();
    toolService = ToolService(storage: storage);
    addTearDown(toolService.dispose);
  });

  group('GetEnvironmentTool.execute', () {
    test('envelope includes active_shell on every platform', () async {
      final tool = GetEnvironmentTool();
      final out = await tool.execute(const <String, dynamic>{}, toolService);
      final payload = jsonDecode(out) as Map<String, dynamic>;

      // Surface contract: every platform exposes `active_shell`
      // so the model can author command syntax accordingly.
      expect(payload['active_shell'], isA<Map<String, dynamic>>());
      final active = payload['active_shell'] as Map<String, dynamic>;
      expect(active['kind'], isA<String>());
      expect(active['executable'], isA<String>());
      expect(active['flag'], isA<String>());
      expect(active['label'], isA<String>());

      if (Platform.isWindows) {
        // The label flows from the resolver; possible values are
        // bash / powershell / cmd. Don't pin a specific value so
        // the test stays green on hosts with different shells
        // installed.
        expect(active['label'], isIn(<String>['bash', 'powershell', 'cmd']));
        // The kind matches the label one of one.
        expect(active['kind'], isIn(<String>['git_bash', 'powershell', 'cmd']));
      } else {
        // POSIX is always `/bin/sh`.
        expect(active['label'], 'sh');
        expect(active['kind'], 'sh');
        expect(active['executable'], '/bin/sh');
        expect(active['flag'], '-c');
      }
    });

    test(
      'Windows: git_bash install path is surfaced when Git Bash is active',
      () async {
        if (!Platform.isWindows) return;
        final tool = GetEnvironmentTool();
        final out = await tool.execute(const <String, dynamic>{}, toolService);
        final payload = jsonDecode(out) as Map<String, dynamic>;
        final active = payload['active_shell'] as Map<String, dynamic>;
        if (active['kind'] != 'git_bash') return; // skip on non-Git-Bash hosts
        // When Git Bash is active, the install path is included
        // without trailing slash and points at <install>\Git.
        final installPath = payload['git_bash_install_path'];
        expect(
          installPath,
          isA<String>(),
          reason: 'expected an install path on this Windows host',
        );
        final path = installPath as String;
        expect(
          path.endsWith(r'\Git'),
          isTrue,
          reason: 'install path must end at the Git folder, got "$path"',
        );
      },
    );
  });
}
