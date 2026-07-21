import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;

import '../platform/windows_shell_resolver.dart';
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
/// [extraPaths] lets callers (currently the Windows Git-Bash path)
/// prepend their own directory list without having to fork the
/// function — entries keep the same dedupe + ordering rules as the
/// built-in standard paths.
///
/// [extraEnv] lets callers merge per-shell environment variables on
/// top of the base env (e.g. `LANG=C.UTF-8` + `LC_ALL=C.UTF-8` for
/// Git Bash so MSYS2 emits UTF-8 instead of inheriting the active
/// Windows code page, which on Chinese hosts is CP936 and mangles
/// Chinese output into mojibake).
///
/// Exposed for testing via [visibleForTesting]; not part of the
/// public API.
@visibleForTesting
Map<String, String> buildShellEnvironment({
  Map<String, String>? baseEnv,
  List<String> extraPaths = const <String>[],
  Map<String, String> extraEnv = const <String, String>{},
}) {
  final env = Map<String, String>.from(baseEnv ?? Platform.environment);
  env.addAll(extraEnv);
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
  // `extraPaths` go FIRST so callers can override the built-in
  // standard paths (e.g. an enterprise install at a non-default
  // location). Built-in standards come next, then whatever was
  // already in the environment.
  for (final entry
      in <String>[...extraPaths, ...stdPaths, ...existing]) {
    if (seen.add(entry)) unique.add(entry);
  }
  env[pathKey] = unique.join(separator);
  return env;
}

/// The `run_command` tool: spawns a one-shot process and returns
/// the captured output. Desktop-only — Android / iOS don't expose a
/// shell to user-facing apps without an extra bridge.
class RunCommandTool extends ToolBase {
  @override
  String get id => 'run_command';
  @override
  String get name => '命令行执行';
  @override
  String get description =>
      '在电脑上执行命令,返回输出结果和退出码。仅 Windows / macOS / Linux 可用。';
  @override
  String get shortDescription => '执行 shell 命令(仅桌面端)';
  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  String get compactSchemaForModel => '''
参数:
- command (string, 必填): 完整命令,通过系统 shell 运行(Windows 默认探测:有 Git Bash 用 `bash -c`(POSIX 语法,推荐),有 PowerShell 用 `pwsh -Command`,最后才回退到 `cmd /c`;macOS/Linux 用 `sh -c`)
- cwd (string, 可选): 工作目录,默认用户工作目录
- timeout_seconds (int, 默认 30, 上限 600): 超时自动 kill

返回: {stdout, stderr, exit_code, duration_ms, timed_out, shell}

最佳实践:
- 想看环境先 get_environment(免去 `uname -a` / `ver` 之类命令);返回里有 `active_shell` 字段告知当前用的 shell,据此撰写命令语法。
- 长任务前先估时间(timeout_seconds),别 600 秒到底,烧光用户耐心。
- shell 不解释管道 / 重定向以外的语法(./script.sh 这种需要先 chmod +x 或直接 sh script.sh)。
- Windows 上若装了 Git Bash(/ Git for Windows),自动以 `bash -c` 解析命令,即可写 POSIX 语法;若只有 PowerShell 走 PowerShell 语法;最后兜底 `cmd /c`,才需要 cmd 语法。
- macOS GUI 启动的 app PATH 很窄,本工具自动 prepend 标准路径(/usr/local/bin, /opt/homebrew/bin 等)。
''';

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
            'cwd': {
              'type': 'string',
              'description': '工作目录,可选,默认使用用户选择的模型工作目录',
            },
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

  /// Resolver used to pick the Windows shell. Created lazily so the
  /// probe cost is amortised across the lifetime of the tool
  /// instance (one probe per app launch). Tests can override via
  /// [overrideWindowsShellResolver].
  WindowsShellResolver? _resolver;

  /// Test seam: swap the resolver so unit tests can assert on
  /// argv construction without spawning a real shell.
  @visibleForTesting
  void overrideWindowsShellResolver(WindowsShellResolver? resolver) {
    _resolver = resolver;
    _cachedShell = null;
  }

  /// Test seam: drop the memoised `WindowsShell` so the next
  /// command re-runs the probe (mirrors what happens if the user
  /// installs Git Bash mid-session).
  @visibleForTesting
  void resetShellCache() {
    _cachedShell = null;
  }

  WindowsShell? _cachedShell;
  Future<WindowsShell>? _pendingShell;

  /// Lazily resolves the Windows shell, memoising the result on
  /// the tool instance. Concurrent `run_command` calls during the
  /// first probe collapse onto a single in-flight future so we
  /// don't fire `where.exe` multiple times in parallel.
  Future<WindowsShell> _resolveWindowsShell() {
    if (_cachedShell != null) return Future.value(_cachedShell);
    final pending = _pendingShell;
    if (pending != null) return pending;
    final resolver = _resolver ?? WindowsShellResolver();
    final future = resolver.shell().then((shell) {
      _cachedShell = shell;
      _pendingShell = null;
      return shell;
    });
    _pendingShell = future;
    return future;
  }

  /// Visible-for-testing seam around [WindowsShellResolver] so we
  /// can assert on the chosen shell + argv without firing
  /// `where.exe` against the live system.
  @visibleForTesting
  Future<WindowsShell> debugResolveWindowsShell({
    WindowsShellResolver? resolver,
  }) {
    final r = resolver ?? _resolver ?? WindowsShellResolver();
    return r.shell();
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

    // Pick the shell + env adjustments. On Windows we delegate to
    // [WindowsShellResolver] so the AI gets the most ergonomic of
    // the available shells (Git Bash > PowerShell > cmd). On
    // macOS / Linux we keep the historical `/bin/sh -c` path.
    final String shellExecutable;
    final List<String> shellArgs;
    final String? resolvedShellLabel;
    final List<String> extraEnvPaths;
    final Map<String, String> extraEnvVars;
    final String commandPrefix;
    if (Platform.isWindows) {
      final shell = await _resolveWindowsShell();
      shellExecutable = shell.executable;
      // The shell may need a UTF-8 nudge BEFORE the user command
      // runs (PowerShell: `[Console]::OutputEncoding = …; chcp
      // 65001 | Out-Null; `, cmd: `chcp 65001 >nul & `). Git Bash
      // doesn't need a prefix because its `LANG` / `LC_ALL`
      // additions (in `shell.envAdditions`) are enough.
      commandPrefix = shell.commandPrefix;
      shellArgs = shell.buildArgv('$commandPrefix$command');
      resolvedShellLabel = shell.flagLabel;
      extraEnvPaths = shell.pathAdditions;
      extraEnvVars = shell.envAdditions;
    } else {
      shellExecutable = '/bin/sh';
      shellArgs = ['-c', command];
      resolvedShellLabel = null;
      extraEnvPaths = const <String>[];
      extraEnvVars = const <String, String>{};
      commandPrefix = '';
    }

    final stopwatch = Stopwatch()..start();
    final env = buildShellEnvironment(
      extraPaths: extraEnvPaths,
      extraEnv: extraEnvVars,
    );
    // NOTE: we deliberately do NOT use `runInShell: true` here.
    // On macOS that wrapper spawns `/bin/sh -c <command>` via
    // `posix_spawn` in a way that drops the inherited environment
    // (PATH comes back empty inside the shell, so even `sysctl`
    // in `/usr/sbin` becomes "command not found"). On Windows the
    // same flag would force `cmd.exe` and bypass our shell choice.
    // Invoking the resolved shell + its flag directly keeps the
    // env we set in `env`.
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

    final decoder = _stdoutDecoder();
    final stdoutFuture = process.stdout.transform(decoder).toList();
    final stderrFuture = process.stderr.transform(decoder).toList();

    final int exitCode;
    bool timedOut = false;
    try {
      exitCode = await process.exitCode.timeout(
        Duration(seconds: timeoutSeconds),
        onTimeout: () {
          process.kill();
          timedOut = true;
          // Return a sentinel exit code so the JSON envelope is
          // uniform; the real "we killed the process" flag is
          // `timed_out`. The AI sees `timed_out: true` and pivots.
          return -1;
        },
      );
    } finally {
      stopwatch.stop();
    }

    // Always drain the streams — even on timeout — so the AI sees
    // partial output for the failed command. Otherwise the futures
    // leak and stdout/stderr fills up the pipe buffer.
    final stdout = (await stdoutFuture).join();
    final stderr = (await stderrFuture).join();
    final Map<String, dynamic> envelope = <String, dynamic>{
      'exit_code': exitCode,
      'stdout': stdout,
      'stderr': stderr,
      'duration_ms': stopwatch.elapsedMilliseconds,
      if (timedOut) 'timed_out': true,
      'shell': ?resolvedShellLabel,
    };
    final encoded = jsonEncode(envelope);
    // Timed-out + zero-exit (still pending) + non-zero exit all
    // surface as a soft error so the model sees the failure and
    // can retry with a smaller scope.
    if (timedOut || exitCode != 0) {
      throw ToolException(encoded);
    }
    return encoded;
  }
}

/// Picks the byte → String decoder for `run_command`'s stdout /
/// stderr streams.
///
/// On Windows we always use UTF-8 (`allowMalformed=true` so a
/// stray non-UTF-8 byte from a misconfigured child becomes `?`
/// instead of throwing). The child shell is forced to emit UTF-8
/// per [WindowsShell.envAdditions] / [WindowsShell.commandPrefix],
/// so the bytes we get should be valid UTF-8 even on hosts where
/// the active code page is CP936 / GBK — without this, every
/// Chinese character from `git log`, `npm`, `python3`, … would
/// decode to `????`.
///
/// On macOS / Linux the system encoding is already UTF-8 in
/// practice, so the system codec is fine and we keep it for
/// backwards-compat with older test fixtures that depend on it.
Converter<List<int>, String> _stdoutDecoder() {
  if (Platform.isWindows) {
    return const Utf8Decoder(allowMalformed: true);
  }
  return systemEncoding.decoder;
}
