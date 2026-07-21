import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// What kind of shell the AI's `run_command` will spawn a command in
/// on Windows. The classification drives both the executable path
/// and the flag used to pass the command string.
enum WindowsShellKind {
  /// Git for Windows (`bash.exe`). POSIX-flavoured — preferred because
  /// the AI's typical shell-flavoured recipes (forward-slash paths,
  /// `$VAR`, backticks, `&&`, `|`, etc.) just work, and the helper
  /// utils (`ls`, `cat`, `awk`, `grep`, `sed` …) all live on PATH
  /// once Git Bash is in scope.
  gitBash,

  /// PowerShell Core (the cross-platform `pwsh.exe` from Microsoft),
  /// or Windows PowerShell 5 (`powershell.exe`) if Core is missing.
  powershell,

  /// Last-resort Windows shell. Always present on Windows; AI
  /// commands mostly need to be re-flavored to cmd syntax
  /// (`%FOO%`, back-slashes, `dir` instead of `ls`, etc.).
  cmd,
}

/// Lightweight value object describing the Windows shell the
/// resolver picked for the current process.
class WindowsShell {
  WindowsShell({
    required this.kind,
    required this.executable,
    required this.flagArg,
    required this.flagLabel,
    this.pathAdditions = const <String>[],
    this.envAdditions = const <String, String>{},
    this.commandPrefix = '',
  });

  /// High-level bucket (`gitBash` / `powershell` / `cmd`).
  final WindowsShellKind kind;

  /// Absolute path to the shell executable. Resolved either from
  /// `where.exe`, a hard-coded candidate (Git for Windows install
  /// layout), or the well-known `cmd.exe` location.
  final String executable;

  /// Argument that signals "run the next arg as a single command".
  /// `-c` for bash / sh; `-Command` for PowerShell. `cmd.exe` uses
  /// `/c` instead and is handled specially in [buildArgv].
  final String flagArg;

  /// Human-readable label of this shell (used for diagnostics +
  /// the `get_environment` tool output). Keep it short — the
  /// surface it lands on is single-line.
  final String flagLabel;

  /// Extra `Path` entries to prepend for the spawned process so
  /// the standard helpers live on `Path`. Empty for `cmd` /
  /// PowerShell (the spawn-time `PATH` is enough); populated for
  /// Git Bash with `<install>/usr/bin` + `<install>/mingw64/bin`
  /// so `ls`, `cat`, etc. resolve without re-launching the shell
  /// just to source `/etc/profile`.
  final List<String> pathAdditions;

  /// Extra environment variables to set on the spawned process so
  /// the shell + its children emit UTF-8 instead of inheriting the
  /// active Windows code page (typically CP936 / GBK on a Chinese
  /// Windows host, which mangles anything Git Bash / PowerShell 7
  /// / modern CLI tools produce as UTF-8). See [buildUtf8Setup].
  final Map<String, String> envAdditions;

  /// Shell-specific prefix prepended to [buildArgv]'s command
  /// argument. Empty for shells that already default to UTF-8
  /// once the environment is set; populated for PowerShell
  /// (`[Console]::OutputEncoding = ...; chcp 65001 | Out-Null; `)
  /// and `cmd.exe` (`chcp 65001 >nul & `) so their child output
  /// is forced to UTF-8 regardless of the active code page.
  final String commandPrefix;

  /// Builds the argv list to spawn this shell with [command].
  ///
  /// Argument ordering matters here. Bash treats `-c <cmd>` as
  /// "the next arg is the command", but long options like
  /// `--noprofile` must come BEFORE `-c` (otherwise bash parses
  /// `--noprofile` as the command argument and chokes). PowerShell
  /// uses `-NoProfile -Command <cmd>`. `cmd.exe` uses `/c <cmd>`.
  ///
  /// See `man bash`: "OPTIONS -- are interpreted by bash itself;
  /// the command is the rest of [the arguments after `-c`]".
  List<String> buildArgv(String command) {
    switch (kind) {
      case WindowsShellKind.gitBash:
        return <String>['--noprofile', flagArg, command];
      case WindowsShellKind.powershell:
        return <String>['-NoProfile', flagArg, command];
      case WindowsShellKind.cmd:
        return <String>['/c', command];
    }
  }
}

/// Lightweight function-type seam for the resolver's process
/// probes. Production wires this up to `Process.run` for
/// `where.exe`. Tests inject a fake that returns synthetic
/// `which`-style output without spawning a child process.
typedef ShellProbe = Future<String?> Function(
  String executable,
  List<String> args,
);

/// Async-friendly `File.exists()` shim for tests.
typedef FileSystemChecker = Future<bool> Function(String path);

/// Picked-once-on-demand Windows shell picker.
///
/// Resolution order on Windows:
///
/// 1. **Git Bash** (`bash.exe` / `sh.exe`) — preferred. The
///    AI's typical shell recipes just work and Git for Windows
///    ships the standard unix utilities on PATH.
///    - Probe order: hard-coded canonical paths →
///      `where.exe git.exe` (derive bash from the install root) →
///      `where.exe bash.exe` → `where.exe sh.exe`.
/// 2. **PowerShell Core** (`pwsh.exe`) — modern preferred. Falls
///    back to Windows PowerShell 5 (`powershell.exe`) if Core is
///    not present.
/// 3. **`cmd.exe`** — last resort. Always present on Windows;
///    the `flagArg` / argv differs from the other two so callers
///    must use [WindowsShell.buildArgv].
///
/// The resolver is async-friendly because the probe shells out to
/// `where.exe`, which is fast enough (<50ms on a warm cache) that
/// the simpler eager-resolution models aren't worth optimising.
/// [shell] memoises the result on the first access so a chat
/// turn that issues many `run_command` calls only pays the probe
/// cost once. Tests can call [resetCache] (or instantiate a
/// fresh resolver) to re-probe.
class WindowsShellResolver {
  WindowsShellResolver({
    ShellProbe? shellProbe,
    FileSystemChecker? fileSystem,
  })  : _probe = shellProbe ?? _defaultProbe,
        _exists = fileSystem ?? _defaultFileExists;

  final ShellProbe _probe;
  final FileSystemChecker _exists;

  WindowsShell? _cached;

  /// The shell to use for `run_command` invocations on Windows.
  /// Resolved lazily on first access; memoised thereafter so
  /// subsequent calls are O(1).
  Future<WindowsShell> shell() async {
    return _cached ??= await _resolve();
  }

  /// Drop the memoised result. Test-only — production code never
  /// calls this because the install layout doesn't change at
  /// runtime (and we'd rather keep the cached probe than re-shell
  /// out to `where.exe` on every call).
  @visibleForTesting
  void resetCache() => _cached = null;

  Future<WindowsShell> _resolve() async {
    if (!Platform.isWindows) {
      // Defensive: callers shouldn't ask us on non-Windows. We
      // pick cmd for predictability — every other Windows-related
      // gate (process flow, path quoting) already exists.
      return _cmdFallback();
    }

    final viaProbe = await _probeGitBash();
    if (viaProbe != null) return viaProbe;
    final pwsh = await _probePwsh();
    if (pwsh != null) return pwsh;
    return _cmdFallback();
  }

  Future<WindowsShell?> _probeGitBash() async {
    // Two competing sources of truth on Windows:
    //
    // 1. The WSL bash stub at
    //    `%LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe` is a
    //    thin wrapper that requires WSL to actually be installed
    //    and configured. If WSL is missing the wrapper errors
    //    out without ever running the command.
    // 2. Git for Windows ships a real `bash.exe` + MinGW-w64
    //    utilities under `C:\Program Files\Git\` (or the
    //    32-bit sibling under `Program Files (x86)`). Always
    //    available when the user has Git installed, doesn't
    //    require any extra setup.
    //
    // Git for Windows is the much more ergonomic choice — it
    // has its own PATH that we can compute statically, and it
    // works whether or not WSL is configured. We therefore look
    // for it FIRST by walking the canonical install locations,
    // and only fall through to `where.exe` (which would prefer
    // the WSL stub on hosts that have both installed) if nothing
    // in the canonical list is found.
    for (final fallback in const <String>[
      // 64-bit canonical Git for Windows.
      r'C:\Program Files\Git\bin\bash.exe',
      r'C:\Program Files\Git\bin\sh.exe',
      r'C:\Program Files\Git\usr\bin\bash.exe',
      r'C:\Program Files\Git\usr\bin\sh.exe',
      // 32-bit / alternative drive layouts.
      r'C:\Program Files (x86)\Git\bin\bash.exe',
      r'C:\Program Files (x86)\Git\bin\sh.exe',
    ]) {
      if (await _exists(fallback)) {
        return _gitBashShell(fallback);
      }
    }
    // Probe `where.exe git.exe` to discover Git installs that
    // don't live under the canonical `C:\Program Files\Git\`
    // path (e.g. a user-installed `D:\Git\`). Derive the install
    // root from `git.exe`'s location, then look for `bash.exe`
    // / `sh.exe` next to it. This sits BEFORE the `where.exe
    // bash.exe` backstop because that backstop resolves to the
    // WSL stub on hosts that have both Git and WSL installed —
    // and the WSL stub errors out instead of running when WSL
    // isn't actually configured.
    final fromGit = await _probeGitBashFromGit();
    if (fromGit != null) return fromGit;
    // PATH-based probe — last backstop for Git Bash. Likely
    // points at the WSL bash stub on machines that have both
    // Git and WSL installed, but that's still a usable POSIX
    // shell.
    for (final name in <String>['bash.exe', 'sh.exe']) {
      final resolved = await _resolveByProbe(name);
      if (resolved != null) {
        return _gitBashShell(resolved);
      }
    }
    return null;
  }

  /// Probe `where.exe git.exe` and derive a Git for Windows
  /// install root from the resolved path, then check the usual
  /// `bash.exe` / `sh.exe` locations under that root.
  ///
  /// Handles every Git-for-Windows layout we know about:
  ///
  ///   `<root>\cmd\git.exe`            — the `cmd/` shim most
  ///                                       installs put on PATH
  ///   `<root>\bin\git.exe`            — older / PortableGit
  ///   `<root>\mingw64\bin\git.exe`    — newer installs, where
  ///                                       the real git binary lives
  Future<WindowsShell?> _probeGitBashFromGit() async {
    final gitPath = await _resolveByProbe('git.exe');
    if (gitPath == null) return null;
    final installRoot = _gitInstallPathFromGit(gitPath);
    if (installRoot == null) return null;
    for (final candidate in <String>[
      '$installRoot\\bin\\bash.exe',
      '$installRoot\\usr\\bin\\bash.exe',
      '$installRoot\\bin\\sh.exe',
      '$installRoot\\usr\\bin\\sh.exe',
    ]) {
      if (await _exists(candidate)) {
        return _gitBashShell(candidate);
      }
    }
    return null;
  }

  WindowsShell _gitBashShell(String executable) => WindowsShell(
        kind: WindowsShellKind.gitBash,
        executable: executable,
        flagArg: '-c',
        flagLabel: 'bash',
        pathAdditions: gitBashPathAdditionsFor(executable),
        // MSYS2 programs (`ls`, `cat`, `git`, `npm`, …) emit UTF-8
        // to stdout/stderr when `LANG` / `LC_ALL` is a UTF-8
        // locale. Pin it explicitly because the inherited
        // Windows-side LANG is often empty (or worse, a
        // system-codepage variant on hosts with the
        // "Beta: Use Unicode UTF-8" toggle off) — in those
        // cases MSYS2 falls back to CP936 and UTF-8 decoding in
        // Dart turns every Chinese character into `?`.
        envAdditions: const <String, String>{
          'LANG': 'C.UTF-8',
          'LC_ALL': 'C.UTF-8',
        },
      );

  Future<WindowsShell?> _probePwsh() async {
    // PowerShell 7 defaults to UTF-8 for `[Console]::OutputEncoding`
    // but Windows PowerShell 5 defaults to the active code page
    // (CP936 on Chinese hosts), and either way external .exe
    // children still respect the Windows code page. Force UTF-8
    // for both PowerShell's own output AND the code page so
    // downstream Win32 tools (`ipconfig`, `systeminfo`, …) emit
    // UTF-8 too.
    const pwshPrefix =
        '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
        'chcp 65001 | Out-Null; ';
    for (final name in <String>['pwsh.exe', 'powershell.exe']) {
      final resolved = await _resolveByProbe(name);
      if (resolved != null) {
        return WindowsShell(
          kind: WindowsShellKind.powershell,
          executable: resolved,
          flagArg: '-Command',
          flagLabel: 'powershell',
          commandPrefix: pwshPrefix,
        );
      }
    }
    for (final fallback in const <String>[
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
    ]) {
      if (await _exists(fallback)) {
        return WindowsShell(
          kind: WindowsShellKind.powershell,
          executable: fallback,
          flagArg: '-Command',
          flagLabel: 'powershell',
          commandPrefix: pwshPrefix,
        );
      }
    }
    return null;
  }

  Future<String?> _resolveByProbe(String name) async {
    final out = await _probe('where.exe', <String>[name]);
    return pickFirstWherePath(out);
  }

  WindowsShell _cmdFallback() => WindowsShell(
        kind: WindowsShellKind.cmd,
        executable: r'C:\Windows\System32\cmd.exe',
        flagArg: '/c',
        flagLabel: 'cmd',
        // `chcp 65001` switches the active code page to UTF-8
        // for the current `cmd.exe` session, so `dir`, `type`,
        // `ipconfig`, etc. — which all write to the console via
        // Win32 — emit UTF-8 bytes to the pipe that Dart reads.
        // `>nul` suppresses `chcp`'s "Active code page: 65001."
        // line; `&` is cmd's unconditional sequence so the
        // user's command still runs even on the (vanishingly
        // rare) host where `chcp 65001` errors out.
        commandPrefix: 'chcp 65001 >nul & ',
      );
}

/// Strip `where.exe`-style trailing CRLF / spaces and grab the
/// first non-blank path on a separate line. Handles paths that
/// contain spaces (`C:\Program Files\Git\bin\bash.exe`) — they're
/// returned on their own line by `where.exe`.
///
/// Returns `null` when stdout is empty or only contains blanks.
@visibleForTesting
String? pickFirstWherePath(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  for (final line in trimmed.split(RegExp(r'\r?\n'))) {
    final t = line.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

/// Figures out the extra `Path` entries Git Bash needs in order
/// for `ls` / `cat` / etc. to resolve without spawning bash just
/// to source its `etc/profile`.
///
/// Layout (Git for Windows):
///
///     <install>\bin\         — sh.exe, bash.exe, git.exe, ssh.exe
///     <install>\usr\bin\     — POSIX utilities (ls, cat, awk, …)
///     <install>\mingw64\bin\ — MinGW-w64 utilities (libssh, …)
///
/// `where.exe` could land on `bash.exe` *or* `sh.exe` *or* the
/// `usr/bin` internal copy. Detect which one we got and walk up
/// the tree to find `<install>`, then re-derive the standard
/// directories.
@visibleForTesting
List<String> gitBashPathAdditionsFor(String bashPath) =>
    _gitBashPathAdditions(bashPath);

@visibleForTesting
String? gitBashInstallPathFor(String bashPath) =>
    _gitBashInstallPath(bashPath);

List<String> _gitBashPathAdditions(String bashPath) {
  // Normalise to back-slashes so we don't have to think about
  // mixed `\` / `/` while walking up the tree.
  final normalised = bashPath.replaceAll('/', r'\');
  final lower = normalised.toLowerCase();
  final parts = normalised.split(r'\').where((p) => p.isNotEmpty).toList();

  // Walk up the path: assume `bash.exe` / `sh.exe` is either in
  // `<root>\bin\` or `<root>\usr\bin\`. The install root is the
  // parent of the parent (usr/bin → 2 segments, bin → 1 segment).
  //
  // NB: the `\usr\bin\` check MUST come first — it's a strict
  // suffix of the bare `\bin\` check, so checking `\bin\` first
  // would mis-route `usr/bin/bash.exe` into the shorter cut.
  String? installRoot;
  if (lower.endsWith(r'\usr\bin\bash.exe') ||
      lower.endsWith(r'\usr\bin\sh.exe')) {
    // Drop `bash.exe`/`sh.exe`, then drop `bin` AND `usr` to
    // reach the install root.
    final parentParts = parts.sublist(0, parts.length - 3);
    installRoot = parentParts.join(r'\');
  } else if (lower.endsWith(r'\bin\bash.exe') ||
      lower.endsWith(r'\bin\sh.exe')) {
    // Drop trailing `bash.exe`/`sh.exe` AND the parent `bin`,
    // leaving us at the install root.
    final parentParts = parts.sublist(0, parts.length - 2);
    installRoot = parentParts.join(r'\');
  }
  if (installRoot == null || installRoot.isEmpty) return const <String>[];

  // Drive-letter prefixes come back as `C:` — re-prefix with the
  // slash separator so the join reads cleanly.
  if (!installRoot.contains(r'\') && installRoot.endsWith(':')) {
    installRoot = '$installRoot\\';
  } else if (installRoot.length == 2 && installRoot.endsWith(':')) {
    installRoot = '$installRoot\\';
  }

  return <String>[
    '$installRoot\\usr\\bin',
    '$installRoot\\mingw64\\bin',
    '$installRoot\\bin',
  ];
}

/// Walks a resolved `bash.exe` / `sh.exe` path back to the Git
/// for Windows install root. Returns `null` when the path
/// doesn't match the canonical layout (e.g. the WSL bash stub).
String? _gitBashInstallPath(String bashPath) {
  // The same dir-walk as `_gitBashPathAdditions` — sharing logic
  // keeps the install-root answer and the path-additions list
  // in sync.
  final lower = bashPath.toLowerCase();
  final parts =
      bashPath.replaceAll('/', r'\').split(r'\').where((p) => p.isNotEmpty).toList();
  if (lower.endsWith(r'\usr\bin\bash.exe') ||
      lower.endsWith(r'\usr\bin\sh.exe')) {
    return parts.take(parts.length - 3).join(r'\');
  }
  if (lower.endsWith(r'\bin\bash.exe') || lower.endsWith(r'\bin\sh.exe')) {
    return parts.take(parts.length - 2).join(r'\');
  }
  return null;
}

/// Walks a resolved `git.exe` path back to the Git for Windows
/// install root. Returns `null` when the path doesn't match any
/// known layout (which means we can't usefully point at a
/// `bash.exe` next to it).
@visibleForTesting
String? gitInstallPathFromGit(String gitPath) =>
    _gitInstallPathFromGit(gitPath);

String? _gitInstallPathFromGit(String gitPath) {
  final normalised = gitPath.replaceAll('/', r'\');
  final lower = normalised.toLowerCase();
  final parts =
      normalised.split(r'\').where((p) => p.isNotEmpty).toList();
  // <root>\cmd\git.exe — the most common layout, where Git for
  // Windows drops the `git.exe` shim on PATH. Drop two segments.
  if (lower.endsWith(r'\cmd\git.exe')) {
    return parts.take(parts.length - 2).join(r'\');
  }
  // <root>\mingw64\bin\git.exe — where the real git binary
  // actually lives on modern installs. Drop three segments.
  if (lower.endsWith(r'\mingw64\bin\git.exe')) {
    return parts.take(parts.length - 3).join(r'\');
  }
  // <root>\bin\git.exe — older Git for Windows / PortableGit.
  // Drop two segments.
  if (lower.endsWith(r'\bin\git.exe')) {
    return parts.take(parts.length - 2).join(r'\');
  }
  return null;
}

// --------------------------------------------------------------------------
// Defaults
// --------------------------------------------------------------------------

Future<String?> _defaultProbe(String executable, List<String> args) async {
  try {
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) return null;
    return result.stdout.toString();
  } on Object {
    return null;
  }
}

Future<bool> _defaultFileExists(String path) async {
  return File(path).exists();
}
