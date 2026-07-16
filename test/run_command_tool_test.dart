import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/services/chat_session_repository.dart';
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
      await tempDir.delete(recursive: true);
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
  });
}
