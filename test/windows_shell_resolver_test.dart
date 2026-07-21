import 'package:agent_buddy/services/platform/windows_shell_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pickFirstWherePath', () {
    test('returns the first non-blank line', () {
      expect(
        pickFirstWherePath('  C:\\Program Files\\Git\\bin\\bash.exe  \r\n'),
        r'C:\Program Files\Git\bin\bash.exe',
      );
    });

    test('handles CRLF + multi-match output', () {
      expect(
        pickFirstWherePath(
          'C:\\Program Files\\Git\\bin\\bash.exe\r\n'
          'C:\\Users\\foo\\bin\\sh.exe\r\n',
        ),
        r'C:\Program Files\Git\bin\bash.exe',
      );
    });

    test('returns null for empty / blank / null input', () {
      expect(pickFirstWherePath(null), isNull);
      expect(pickFirstWherePath(''), isNull);
      expect(pickFirstWherePath('   \r\n'), isNull);
      expect(pickFirstWherePath('\r\n  \r\n'), isNull);
    });

    test('treats LF line endings only', () {
      expect(
        pickFirstWherePath('/usr/bin/sh\n/usr/local/bin/sh'),
        '/usr/bin/sh',
      );
    });
  });

  group('gitBashPathAdditionsFor', () {
    test('C:\\Program Files\\Git\\bin\\bash.exe → install root + usr/mingw/bin',
        () {
      expect(
        gitBashPathAdditionsFor(r'C:\Program Files\Git\bin\bash.exe'),
        <String>[
          r'C:\Program Files\Git\usr\bin',
          r'C:\Program Files\Git\mingw64\bin',
          r'C:\Program Files\Git\bin',
        ],
      );
    });

    test('sh.exe in <root>\\bin\\ yields the same set', () {
      expect(
        gitBashPathAdditionsFor(r'C:\Program Files\Git\bin\sh.exe'),
        <String>[
          r'C:\Program Files\Git\usr\bin',
          r'C:\Program Files\Git\mingw64\bin',
          r'C:\Program Files\Git\bin',
        ],
      );
    });

    test('<root>\\usr\\bin\\bash.exe walks two parents up', () {
      expect(
        gitBashPathAdditionsFor(r'C:\Program Files\Git\usr\bin\bash.exe'),
        <String>[
          r'C:\Program Files\Git\usr\bin',
          r'C:\Program Files\Git\mingw64\bin',
          r'C:\Program Files\Git\bin',
        ],
      );
    });

    test('a different drive letter is preserved', () {
      expect(
        gitBashPathAdditionsFor(r'D:\tools\Git\bin\bash.exe'),
        <String>[
          r'D:\tools\Git\usr\bin',
          r'D:\tools\Git\mingw64\bin',
          r'D:\tools\Git\bin',
        ],
      );
    });

    test('forward slashes are normalised before walking', () {
      expect(
        gitBashPathAdditionsFor(r'C:/Program Files/Git/bin/bash.exe'),
        <String>[
          r'C:\Program Files\Git\usr\bin',
          r'C:\Program Files\Git\mingw64\bin',
          r'C:\Program Files\Git\bin',
        ],
      );
    });

    test('unrecognised layouts return empty (no install root guess)', () {
      expect(gitBashPathAdditionsFor(r'C:\totally\random\bash.exe'), isEmpty);
      expect(gitBashPathAdditionsFor('bash.exe'), isEmpty);
    });
  });

  group('gitInstallPathFromGit', () {
    test('<root>\\cmd\\git.exe → <root>', () {
      expect(
        gitInstallPathFromGit(r'D:\Git\cmd\git.exe'),
        r'D:\Git',
      );
    });

    test('<root>\\mingw64\\bin\\git.exe → <root>', () {
      expect(
        gitInstallPathFromGit(r'C:\Program Files\Git\mingw64\bin\git.exe'),
        r'C:\Program Files\Git',
      );
    });

    test('<root>\\bin\\git.exe (PortableGit) → <root>', () {
      expect(
        gitInstallPathFromGit(r'E:\portable\Git\bin\git.exe'),
        r'E:\portable\Git',
      );
    });

    test('forward slashes are normalised', () {
      expect(
        gitInstallPathFromGit(r'D:/Git/cmd/git.exe'),
        r'D:\Git',
      );
    });

    test('unrecognised layouts return null', () {
      expect(gitInstallPathFromGit(r'C:\Windows\System32\git.exe'), isNull);
      expect(gitInstallPathFromGit('git.exe'), isNull);
      expect(gitInstallPathFromGit(r'C:\foo\bar\git.exe'), isNull);
    });
  });

  group('WindowsShell.buildArgv', () {
    test('gitBash: --noprofile -c <cmd> (long opts go BEFORE -c)', () {
      final shell = WindowsShell(
        kind: WindowsShellKind.gitBash,
        executable: r'C:\Program Files\Git\bin\bash.exe',
        flagArg: '-c',
        flagLabel: 'bash',
      );
      expect(shell.buildArgv('echo hi'), <String>[
        '--noprofile',
        '-c',
        'echo hi',
      ]);
    });

    test('powershell: -NoProfile -Command <cmd>', () {
      final shell = WindowsShell(
        kind: WindowsShellKind.powershell,
        executable: r'C:\Program Files\PowerShell\7\pwsh.exe',
        flagArg: '-Command',
        flagLabel: 'powershell',
      );
      expect(shell.buildArgv('Get-Date'), <String>[
        '-NoProfile',
        '-Command',
        'Get-Date',
      ]);
    });

    test('cmd: /c <cmd>', () {
      final shell = WindowsShell(
        kind: WindowsShellKind.cmd,
        executable: r'C:\Windows\System32\cmd.exe',
        flagArg: '/c',
        flagLabel: 'cmd',
      );
      expect(shell.buildArgv('echo hi'), <String>['/c', 'echo hi']);
    });
  });

  group('WindowsShell UTF-8 setup', () {
    test('gitBash pins LANG=LC_ALL=C.UTF-8 so MSYS2 emits UTF-8', () {
      final shell = WindowsShell(
        kind: WindowsShellKind.gitBash,
        executable: r'D:\Git\bin\bash.exe',
        flagArg: '-c',
        flagLabel: 'bash',
        envAdditions: const <String, String>{
          'LANG': 'C.UTF-8',
          'LC_ALL': 'C.UTF-8',
        },
      );
      expect(shell.envAdditions, <String, String>{
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
      });
      // Git Bash doesn't need a command prefix — LANG alone
      // forces UTF-8 output from MSYS2 programs.
      expect(shell.commandPrefix, isEmpty);
    });

    test('powershell sets Console.OutputEncoding + chcp 65001', () {
      final shell = WindowsShell(
        kind: WindowsShellKind.powershell,
        executable: r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        flagArg: '-Command',
        flagLabel: 'powershell',
        commandPrefix:
            '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
            'chcp 65001 | Out-Null; ',
      );
      expect(shell.commandPrefix, startsWith('[Console]::OutputEncoding'));
      expect(shell.commandPrefix, contains('chcp 65001'));
      expect(shell.commandPrefix, contains('Out-Null'));
      expect(shell.envAdditions, isEmpty);
    });

    test('cmd prefixes chcp 65001 >nul & so cmd children emit UTF-8', () {
      final shell = WindowsShell(
        kind: WindowsShellKind.cmd,
        executable: r'C:\Windows\System32\cmd.exe',
        flagArg: '/c',
        flagLabel: 'cmd',
        commandPrefix: 'chcp 65001 >nul & ',
      );
      expect(shell.commandPrefix, 'chcp 65001 >nul & ');
      expect(shell.envAdditions, isEmpty);
    });
  });

  group('WindowsShellResolver (synthetic probe)', () {
    Future<WindowsShell> resolve({
      Map<String, String> probeMap = const <String, String>{},
      Set<String> existingPaths = const <String>{},
    }) async {
      final resolver = WindowsShellResolver(
        shellProbe: (exe, args) async {
          final key = '$exe ${args.join(' ')}';
          return probeMap[key];
        },
        fileSystem: (path) async => existingPaths.contains(path),
      );
      return resolver.shell();
    }

    test('picks git bash when bash.exe resolves via where.exe', () async {
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe': r'C:\Program Files\Git\bin\bash.exe',
        },
      );
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(shell.executable, r'C:\Program Files\Git\bin\bash.exe');
      expect(shell.flagArg, '-c');
      expect(shell.flagLabel, 'bash');
      // PathAdditions must point at <install>\usr\bin etc.
      expect(shell.pathAdditions, contains(r'C:\Program Files\Git\usr\bin'));
      expect(shell.pathAdditions, contains(r'C:\Program Files\Git\mingw64\bin'));
    });

    test('falls back to sh.exe when bash.exe is missing', () async {
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe': '',
          'where.exe sh.exe': r'C:\Program Files\Git\bin\sh.exe',
        },
      );
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(shell.executable, r'C:\Program Files\Git\bin\sh.exe');
    });

    test('falls back to canonical path when where.exe fails', () async {
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe': '',
          'where.exe sh.exe': '',
        },
        existingPaths: <String>{
          r'C:\Program Files\Git\bin\bash.exe',
          r'C:\Program Files\Git\usr\bin',
        },
      );
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(shell.executable, r'C:\Program Files\Git\bin\bash.exe');
    });

    test('canonical Git install wins over the WSL bash stub on `where.exe`',
        () async {
      // Pre-install a phantom Git for Windows AND a phantom WSL
      // stub on the where.exe side. The resolver should pick the
      // Git install (canonical paths win) over the stub.
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe':
              r'C:\Users\foo\AppData\Local\Microsoft\WindowsApps\bash.exe',
          'where.exe sh.exe': '',
        },
        existingPaths: <String>{
          r'C:\Program Files\Git\bin\bash.exe',
          r'C:\Program Files\Git\usr\bin',
        },
      );
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(
        shell.executable,
        r'C:\Program Files\Git\bin\bash.exe',
        reason: 'Git for Windows must win over the WSL bash stub',
      );
    });

    test(
        'derives bash from git.exe when Git is installed off-canonical '
        '(e.g. D:\\Git\\)', () async {
      // Simulates a host where Git lives under D:\Git\ — the
      // canonical-path fallback misses it AND `where.exe bash.exe`
      // resolves to the WSL relay (broken when WSL isn't
      // installed). The git-derived path must take priority.
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe git.exe': r'D:\Git\cmd\git.exe',
          'where.exe bash.exe': r'C:\Windows\System32\bash.exe',
          'where.exe sh.exe': '',
        },
        existingPaths: <String>{
          r'D:\Git\bin\bash.exe',
          r'D:\Git\usr\bin',
        },
      );
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(
        shell.executable,
        r'D:\Git\bin\bash.exe',
        reason: 'must derive bash from the git.exe install root',
      );
      // Path additions must point at the D:\Git\ install, not
      // any C:\Program Files\Git\ path.
      expect(shell.pathAdditions, <String>[
        r'D:\Git\usr\bin',
        r'D:\Git\mingw64\bin',
        r'D:\Git\bin',
      ]);
    });

    test('falls through to where.exe bash.exe when git.exe is not on PATH',
        () async {
      // WSL bash stub on PATH, no Git install anywhere. Resolver
      // should still find a POSIX shell via the bash.exe
      // backstop.
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe git.exe': '',
          'where.exe bash.exe':
              r'C:\Users\foo\AppData\Local\Microsoft\WindowsApps\bash.exe',
          'where.exe sh.exe': '',
        },
      );
      expect(shell.kind, WindowsShellKind.gitBash);
      expect(
        shell.executable,
        r'C:\Users\foo\AppData\Local\Microsoft\WindowsApps\bash.exe',
      );
    });

    test('prefers pwsh.exe over powershell.exe when both resolve', () async {
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe': '',
          'where.exe sh.exe': '',
          'where.exe pwsh.exe':
              r'C:\Program Files\PowerShell\7\pwsh.exe',
          'where.exe powershell.exe':
              r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        },
      );
      expect(shell.kind, WindowsShellKind.powershell);
      expect(shell.executable, r'C:\Program Files\PowerShell\7\pwsh.exe');
      expect(shell.flagArg, '-Command');
      expect(shell.flagLabel, 'powershell');
      // No pathAdditions — PowerShell inherits the spawn env.
      expect(shell.pathAdditions, isEmpty);
    });

    test('falls back to Windows PowerShell 5 when Core is missing',
        () async {
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe': '',
          'where.exe sh.exe': '',
          'where.exe pwsh.exe': '',
          'where.exe powershell.exe':
              r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
        },
      );
      expect(shell.kind, WindowsShellKind.powershell);
      expect(
        shell.executable,
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      );
    });

    test('falls back to cmd.exe when nothing else exists', () async {
      final shell = await resolve(
        probeMap: <String, String>{
          'where.exe bash.exe': '',
          'where.exe sh.exe': '',
          'where.exe pwsh.exe': '',
          'where.exe powershell.exe': '',
        },
      );
      expect(shell.kind, WindowsShellKind.cmd);
      expect(shell.executable, r'C:\Windows\System32\cmd.exe');
      expect(shell.flagArg, '/c');
      expect(shell.flagLabel, 'cmd');
    });

    test('memoises the resolved shell', () async {
      var bashCalls = 0;
      // Inject a file-system checker that rejects every path so
      // the resolver has to go through `where.exe` rather than
      // short-circuiting via the canonical-path fallback. This
      // keeps the test deterministic regardless of what's
      // actually installed on the host.
      final resolver = WindowsShellResolver(
        shellProbe: (exe, args) async {
          if (exe == 'where.exe' && args.contains('bash.exe')) {
            bashCalls += 1;
          }
          return exe == 'where.exe' && args.contains('bash.exe')
              ? r'C:\Program Files\Git\bin\bash.exe'
              : '';
        },
        fileSystem: (_) async => false,
      );
      await resolver.shell();
      await resolver.shell();
      await resolver.shell();
      expect(bashCalls, 1, reason: 'probe must fire only once per instance');
    });
  });
}
