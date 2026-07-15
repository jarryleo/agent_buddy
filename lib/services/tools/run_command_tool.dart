import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;

import '../tool_service.dart';
import 'tool_base.dart';

/// Build the environment map passed to [Process.start] when running
/// a shell command.
///
/// macOS apps launched as a GUI bundle (i.e. from Finder) inherit a
/// minimal PATH from launchd that typically omits `/usr/sbin`
/// (`sysctl`, `system_profiler`, `ifconfig`, …) and Apple-Silicon
/// Homebrew at `/opt/homebrew/bin`. Without help, common shell
/// recipes fail with `command not found`. We prepend the canonical
/// system paths to whatever the parent already exports, deduped and
/// order-preserving, so the shell can find the standard utilities.
/// The Windows variant covers `cmd.exe` / PowerShell being reachable
/// from a freshly-spawned shell.
///
/// Exposed for testing via [visibleForTesting]; not part of the
/// public API.
@visibleForTesting
Map<String, String> buildShellEnvironment({Map<String, String>? baseEnv}) {
  final env = Map<String, String>.from(baseEnv ?? Platform.environment);
  final pathKey = Platform.isWindows ? 'Path' : 'PATH';
  final separator = Platform.isWindows ? ';' : ':';
  final stdPaths = Platform.isWindows
      ? const <String>[
          r'C:\Windows\System32',
          r'C:\Windows',
          r'C:\Windows\System32\Wbem',
          r'C:\Windows\System32\WindowsPowerShell\v1.0',
          r'C:\Windows\System32\OpenSSH',
        ]
      : const <String>[
          '/opt/homebrew/bin', // Apple-Silicon Homebrew
          '/usr/local/bin', // Intel Homebrew / manual installs
          '/usr/bin',
          '/bin',
          '/usr/sbin',
          '/sbin',
        ];
  final existing = (env[pathKey] ?? '')
      .split(separator)
      .where((s) => s.isNotEmpty);
  final seen = <String>{};
  final unique = <String>[];
  for (final entry in <String>[...stdPaths, ...existing]) {
    if (seen.add(entry)) unique.add(entry);
  }
  env[pathKey] = unique.join(separator);
  return env;
}

class RunCommandTool extends ToolBase {
  @override
  String get id => 'run_command';
  @override
  String get name => '命令行执行';
  @override
  String get description => '在电脑上执行命令,返回输出结果和退出码。仅 Windows / macOS / Linux 可用。';
  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'run_command',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': '要执行的命令(通过系统 shell 运行)',
            },
            'cwd': {'type': 'string', 'description': '工作目录,可选,默认使用用户选择的模型工作目录'},
            'timeout_seconds': {
              'type': 'integer',
              'description': '超时秒数,默认 30,超时自动杀掉',
              'default': 30,
              'minimum': 1,
              'maximum': 600,
            },
          },
          'required': ['command'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    if (kIsWeb) {
      throw ToolException('run_command is not supported on web');
    }
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw ToolException(
        'run_command is only supported on desktop (macOS / Windows / Linux)',
      );
    }
    final command = (args['command'] as String? ?? '').trim();
    if (command.isEmpty) {
      throw ToolException('command must not be empty');
    }
    final requestedCwd = (args['cwd'] as String?)?.trim();
    final defaultCwd = services.workingDirectory;
    final cwd = requestedCwd == null || requestedCwd.isEmpty
        ? defaultCwd
        : p.isAbsolute(requestedCwd) || defaultCwd == null
        ? requestedCwd
        : p.normalize(p.join(defaultCwd, requestedCwd));
    final timeoutSeconds = (args['timeout_seconds'] as num?)?.toInt() ?? 30;

    final env = buildShellEnvironment();
    // NOTE: we deliberately do NOT use `runInShell: true` here.
    // On macOS that wrapper spawns `/bin/sh -c <command>` via
    // `posix_spawn` in a way that drops the inherited environment
    // (PATH comes back empty inside the shell, so even `sysctl`
    // in `/usr/sbin` becomes "command not found"). Invoking the
    // shell + `-c` directly keeps the env we set in `env`.
    final String shellExecutable;
    final List<String> shellArgs;
    if (Platform.isWindows) {
      shellExecutable = 'cmd.exe';
      shellArgs = ['/c', command];
    } else {
      shellExecutable = '/bin/sh';
      shellArgs = ['-c', command];
    }
    final Process process;
    try {
      process = await Process.start(
        shellExecutable,
        shellArgs,
        workingDirectory: cwd,
        environment: env,
      );
    } catch (e) {
      throw ToolException('failed to start command: $e');
    }

    final decoder = systemEncoding.decoder;
    final stdoutFuture = process.stdout.transform(decoder).toList();
    final stderrFuture = process.stderr.transform(decoder).toList();

    final exitCode = await process.exitCode.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        process.kill();
        throw TimeoutException('command timed out after ${timeoutSeconds}s');
      },
    );

    final stdout = (await stdoutFuture).join();
    final stderr = (await stderrFuture).join();

    final payload = jsonEncode({
      'exit_code': exitCode,
      'stdout': stdout,
      'stderr': stderr,
    });
    if (exitCode != 0) {
      throw ToolException(payload);
    }
    return payload;
  }
}
