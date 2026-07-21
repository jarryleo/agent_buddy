import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../platform/windows_shell_resolver.dart';
import '../tool_service.dart';
import 'tool_base.dart';

class GetEnvironmentTool extends ToolBase {
  @override
  String get id => 'get_environment';
  @override
  String get name => '环境信息';
  @override
  String get description =>
      '查看本机系统信息(系统类型、架构、用户名、当前进程实际调用的 shell 等)。执行命令前先看看环境。仅桌面端可用。';
  @override
  String get shortDescription => '查看系统/平台信息(仅桌面端)';
  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'get_environment',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': const <String, dynamic>{},
          'additionalProperties': false,
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
      throw ToolException('get_environment is not supported on web');
    }
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw ToolException(
        'get_environment is only supported on desktop (macOS / Windows / Linux)',
      );
    }

    Future<String> runShell(String executable, List<String> args) async {
      try {
        final result = await Process.run(
          executable,
          args,
          runInShell: true,
        ).timeout(const Duration(seconds: 5));
        return result.stdout.toString().trim();
      } catch (_) {
        return '';
      }
    }

    final isWin = Platform.isWindows;
    final kernel = await runShell(
      isWin ? 'cmd' : 'uname',
      isWin ? ['/c', 'ver'] : ['-a'],
    );
    final arch = isWin
        ? (Platform.environment['PROCESSOR_ARCHITECTURE'] ??
              (await runShell('cmd', ['/c', 'echo %PROCESSOR_ARCHITECTURE%'])))
        : (await runShell('uname', ['-m']));

    // Surface the same shell `run_command` would actually spawn so
    // the model knows which syntax to author commands in. Probing
    // happens once per tool instance; subsequent calls are O(1) on
    // the memoised result.
    final Map<String, dynamic> activeShell;
    String? bashInstall;
    if (isWin) {
      final WindowsShell shell =
          _cachedWindowsShell ??= await _resolveWindowsShell();
      activeShell = <String, dynamic>{
        'kind': _kindLabel(shell.kind),
        'executable': shell.executable,
        'flag': shell.flagArg,
        'label': shell.flagLabel,
      };
      if (shell.kind == WindowsShellKind.gitBash) {
        bashInstall = _stripTrailingSeparator(
          gitBashInstallPathFor(shell.executable), // ignore: invalid_use_of_visible_for_testing_member
        );
      }
    } else {
      activeShell = <String, dynamic>{
        'kind': 'sh',
        'executable': '/bin/sh',
        'flag': '-c',
        'label': 'sh',
      };
    }

    return jsonEncode({
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'arch': arch.isEmpty ? 'unknown' : arch,
      'hostname': Platform.localHostname,
      'user':
          Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          'unknown',
      'home':
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '',
      'shell':
          Platform.environment['SHELL'] ??
          Platform.environment['COMSPEC'] ??
          '',
      'cwd': services.workingDirectory ?? Directory.current.path,
      'num_processors': Platform.numberOfProcessors,
      'kernel': kernel.isEmpty ? Platform.operatingSystemVersion : kernel,
      // `run_command` will dispatch via this shell. On Windows
      // it's the picked Git-Bash / PowerShell / cmd; on POSIX
      // it's `/bin/sh`. Use this to author command syntax.
      'active_shell': activeShell,
      'git_bash_install_path': ?bashInstall,
    });
  }

  WindowsShell? _cachedWindowsShell;

  Future<WindowsShell> _resolveWindowsShell() {
    final resolver = WindowsShellResolver();
    return resolver.shell();
  }

  String _kindLabel(WindowsShellKind kind) => switch (kind) {
        WindowsShellKind.gitBash => 'git_bash',
        WindowsShellKind.powershell => 'powershell',
        WindowsShellKind.cmd => 'cmd',
      };

  static String? _stripTrailingSeparator(String? path) {
    if (path == null) return null;
    var s = path;
    while (s.endsWith(r'\') || s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s.isEmpty ? null : s;
  }
}
