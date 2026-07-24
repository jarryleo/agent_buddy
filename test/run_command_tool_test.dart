import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/platform/windows_shell_resolver.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/run_command_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ToolService toolService;

  setUpAll(ChatSessionRepository.registerAdapters);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final tempDir = await Directory.systemTemp.createTemp('run_command_tool_');
    Hive.init(tempDir.path);
    addTearDown(() async {
      // Windows sometimes holds a lingering handle on the temp
      // dir when the prior test spawned a child process. Retry
      // a few times before giving up — the tests themselves are
      // passing; the failure is only in the cleanup.
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

  group('buildShellEnvironment', () {
    test('prepends /usr/sbin and /opt/homebrew/bin on macOS', () {
      if (!Platform.isMacOS) return;
      final result = buildShellEnvironment(baseEnv: {'PATH': '/usr/bin:/bin'});
      final parts = (result['PATH'] ?? '').split(':');
      expect(parts.first, '/opt/homebrew/bin');
      expect(
        parts,
        containsAll(<String>[
          '/opt/homebrew/bin',
          '/usr/local/bin',
          '/usr/bin',
          '/bin',
          '/usr/sbin',
          '/sbin',
        ]),
      );
      // Original entries are preserved.
      expect(parts, contains('/usr/bin'));
      expect(parts, contains('/bin'));
    });

    test('prepends /usr/sbin on Linux', () {
      if (!Platform.isLinux) return;
      final result = buildShellEnvironment(baseEnv: {'PATH': '/usr/bin:/bin'});
      final parts = (result['PATH'] ?? '').split(':');
      expect(parts, contains('/usr/sbin'));
      expect(parts, contains('/usr/bin'));
    });

    test('prepends System32 on Windows', () {
      if (!Platform.isWindows) return;
      final result = buildShellEnvironment(baseEnv: {'Path': r'C:\Windows'});
      final parts = (result['Path'] ?? '').split(';');
      expect(parts, contains(r'C:\Windows\System32'));
      expect(parts, contains(r'C:\Windows'));
    });

    test('dedupes overlapping standard + existing paths', () {
      final baseEnv = Platform.isWindows
          ? <String, String>{
              'Path': r'C:\Windows\System32;C:\Windows\System32\Wbem',
            }
          : <String, String>{'PATH': '/usr/bin:/bin:/usr/sbin'};
      final result = buildShellEnvironment(baseEnv: baseEnv);
      final pathKey = Platform.isWindows ? 'Path' : 'PATH';
      final separator = Platform.isWindows ? ';' : ':';
      final parts = (result[pathKey] ?? '').split(separator);
      expect(
        parts.toSet().length,
        parts.length,
        reason: 'PATH must not contain duplicates',
      );
    });

    test('handles an empty / missing PATH without crashing', () {
      final result = buildShellEnvironment(baseEnv: <String, String>{});
      final pathKey = Platform.isWindows ? 'Path' : 'PATH';
      expect(result[pathKey], isNotNull);
      expect(result[pathKey]!.isNotEmpty, isTrue);
    });

    test('extraPaths come BEFORE the built-in standards', () {
      if (!Platform.isWindows) return;
      final result = buildShellEnvironment(
        baseEnv: <String, String>{},
        extraPaths: <String>[r'D:\custom\bin'],
      );
      final parts = (result['Path'] ?? '').split(';');
      expect(
        parts.first,
        r'D:\custom\bin',
        reason: 'extraPaths must precede the built-in standards',
      );
      expect(parts, contains(r'C:\Windows\System32'));
    });

    test('extraPaths win when they collide with the built-in standards', () {
      if (!Platform.isWindows) return;
      final result = buildShellEnvironment(
        baseEnv: <String, String>{},
        extraPaths: <String>[r'C:\Windows\System32'],
      );
      final parts = (result['Path'] ?? '').split(';');
      // No duplicates — `extraPaths` overlaps with a standard.
      expect(parts.where((p) => p == r'C:\Windows\System32').length, 1);
    });

    test('extraEnv overrides the base env (per-shell UTF-8 vars)', () {
      final result = buildShellEnvironment(
        baseEnv: <String, String>{'LANG': 'C', 'OTHER': 'keep'},
        extraEnv: const <String, String>{
          'LANG': 'C.UTF-8',
          'LC_ALL': 'C.UTF-8',
        },
      );
      expect(
        result['LANG'],
        'C.UTF-8',
        reason: 'extraEnv must win over the inherited env',
      );
      expect(result['LC_ALL'], 'C.UTF-8');
      // Untouched keys pass through.
      expect(result['OTHER'], 'keep');
    });
  });

  group('RunCommandTool.execute', () {
    test('rejects an empty command', () async {
      final tool = RunCommandTool();
      await expectLater(
        tool.execute({'command': '   '}, toolService),
        throwsA(isA<ToolException>()),
      );
    });

    test('runs a command in /usr/sbin on macOS (the original bug)', () async {
      if (!Platform.isMacOS) return;
      final tool = RunCommandTool();
      final out = await tool.execute({
        'command': 'sysctl -n hw.ncpu',
        'timeout_seconds': 5,
      }, toolService);
      final payload = jsonDecode(out) as Map<String, dynamic>;
      expect(payload['exit_code'], 0);
      expect(payload['stderr'], isNot(contains('command not found')));
      // hw.ncpu is always a positive integer on real Macs.
      expect(int.tryParse('${payload['stdout']}'.trim()), greaterThan(0));
    });

    test('returns a JSON envelope with non-zero exit on failure', () async {
      final tool = RunCommandTool();
      try {
        await tool.execute({
          'command': 'false',
          'timeout_seconds': 5,
        }, toolService);
        fail('expected ToolException');
      } on ToolException catch (e) {
        final payload = jsonDecode(e.message) as Map<String, dynamic>;
        expect(payload['exit_code'], 1);
      }
    });

    test('honors an absolute cwd override', () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final tool = RunCommandTool();
      final out = await tool.execute({
        'command': 'pwd',
        'cwd': '/tmp',
        'timeout_seconds': 5,
      }, toolService);
      final payload = jsonDecode(out) as Map<String, dynamic>;
      expect(payload['exit_code'], 0);
      // On macOS /tmp is a symlink to /private/tmp; pwd resolves it.
      final stdout = '${payload['stdout']}'.trim();
      expect(
        stdout == '/tmp' || stdout == '/private/tmp',
        isTrue,
        reason: 'expected pwd to land in /tmp, got "$stdout"',
      );
    });

    test('envelope carries the resolved shell label on Windows', () async {
      if (!Platform.isWindows) return;
      final tool = RunCommandTool();
      final out = await tool.execute({
        'command': 'echo hi',
        'timeout_seconds': 5,
      }, toolService);
      final payload = jsonDecode(out) as Map<String, dynamic>;
      expect(payload['exit_code'], 0);
      // `shell` is one of bash / powershell / cmd depending on
      // whatever the resolver picked for this host. Don't pin
      // a specific label — different machines have different
      // installs — but require the field to be present.
      expect(payload['shell'], isIn(<String>['bash', 'powershell', 'cmd']));
      expect(payload['duration_ms'], isA<int>());
    });

    test('uses the resolved shell when overridden via the test seam', () async {
      // Inject a fake resolver that always reports Git Bash at
      // a path we know is real on Windows. This sidesteps the
      // `where.exe` probe so the test stays deterministic on any
      // machine (no real Git Bash install required for the
      // assertion), while still letting us verify the tool picks
      // up the right argv construction.
      if (!Platform.isWindows) return;
      final tool = RunCommandTool();
      final fakeResolver = WindowsShellResolver(
        shellProbe: (exe, args) async {
          if (exe == 'where.exe' && args.contains('bash.exe')) {
            return r'C:\Program Files\Git\bin\bash.exe';
          }
          return '';
        },
        fileSystem: (_) async => false,
      );
      final shell = await tool.debugResolveWindowsShell(resolver: fakeResolver);
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(shell.executable, r'C:\Program Files\Git\bin\bash.exe');
      expect(shell.flagArg, '-c');
      // The argv the tool would pass to Process.start. We don't
      // actually spawn — we just verify the structure that bash
      // would receive.
      expect(shell.buildArgv(r'echo $PATH'), <String>[
        '--noprofile',
        '-c',
        r'echo $PATH',
      ]);
      expect(
        shell.pathAdditions,
        containsAll(<String>[
          r'C:\Program Files\Git\usr\bin',
          r'C:\Program Files\Git\mingw64\bin',
          r'C:\Program Files\Git\bin',
        ]),
      );
    });

    test('Windows Git Bash: echo with Chinese returns Chinese (no mojibake) '
        'when LANG=C.UTF-8 is set', () async {
      // On Chinese Windows, the active code page is CP936 / GBK
      // but MSYS2 (Git Bash) defaults to emitting UTF-8. Without
      // the LANG=LC_ALL=C.UTF-8 env additions and the UTF-8
      // decoder, `echo 你好` would come back as `????`. This
      // test pins the round-trip end-to-end so a future change
      // can't silently regress it.
      if (!Platform.isWindows) return;
      final tool = RunCommandTool();
      // Let the default resolver find whatever real Git Bash
      // the host has (or skip if none).
      final shell = await tool.debugResolveWindowsShell();
      if (shell.kind != WindowsShellKind.gitBash) {
        // No Git Bash on this host — can't exercise the path.
        return;
      }
      if (!File(shell.executable).existsSync()) return;
      final out = await tool.execute({
        'command': 'echo 你好世界',
        'timeout_seconds': 10,
      }, toolService);
      final payload = jsonDecode(out) as Map<String, dynamic>;
      expect(payload['exit_code'], 0);
      final stdout = '${payload['stdout']}';
      expect(
        stdout,
        contains('你好世界'),
        reason:
            'stdout must contain the original Chinese, '
            'not mojibake. Got: $stdout',
      );
      // Must NOT contain the GBK-decoded replacement chars.
      expect(
        stdout,
        isNot(contains('?好')),
        reason: 'looks like GBK-decoded UTF-8 mojibake: $stdout',
      );
      expect(payload['shell'], 'bash');
    });
  });
}
