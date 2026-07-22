import 'dart:async';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:path/path.dart' as p;

import 'autostart_service.dart';
import 'autostart_service_stub.dart';

/// Production factory: returns the per-OS concrete implementation on
/// Windows / macOS / Linux and a no-op stub on mobile / web.
///
/// The "io" suffix mirrors `file_service_io.dart` / `location_service_io.dart`
/// — the pattern in this repo is one factory, one stub, and the
/// factory picks at runtime so the dart:io import stays scoped to
/// desktop code (no web / mobile import noise).
AutostartService createAutostartService({
  String? executablePathOverride,
  String? homeDirectoryOverride,
  String appName = 'Agent Buddy',
  String linuxDesktopEntryName = 'agent-buddy',
  String macBundleId = 'com.agentbuddy.app',
}) {
  if (isAutostartSupportedOnCurrentPlatform()) {
    if (Platform.isWindows) {
      return WindowsAutostartService(
        appName: appName,
        executablePathOverride: executablePathOverride,
      );
    }
    if (Platform.isMacOS) {
      return MacAutostartService(
        appName: appName,
        bundleId: macBundleId,
        executablePathOverride: executablePathOverride,
        homeDirectoryOverride: homeDirectoryOverride,
      );
    }
    if (Platform.isLinux) {
      return LinuxAutostartService(
        appName: appName,
        desktopEntryName: linuxDesktopEntryName,
        executablePathOverride: executablePathOverride,
        homeDirectoryOverride: homeDirectoryOverride,
      );
    }
  }
  return const AutostartServiceStub();
}

// ---------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------

/// Auto-start via the per-user `Run` registry key under
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. The value
/// name defaults to `AgentBuddy`; the value is the absolute path
/// of the running executable wrapped in quotes so paths with
/// spaces survive. We use `HKCU` (current user) rather than
/// `HKLM` so the app doesn't need elevated rights — and a per-user
/// run key is what most user-facing apps use anyway.
class WindowsAutostartService implements AutostartService {
  WindowsAutostartService({
    String appName = 'Agent Buddy',
    String? executablePathOverride,
  }) : _valueName = _sanitizeValueName(appName),
       _executablePathOverride = executablePathOverride;

  /// HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  static const String _runKey =
      'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run';

  final String _valueName;
  final String? _executablePathOverride;

  @override
  bool get isSupported => true;

  String _resolveExecutable() {
    final override = _executablePathOverride;
    if (override != null && override.isNotEmpty) return override;
    return Platform.resolvedExecutable;
  }

  static String _sanitizeValueName(String appName) {
    // Registry value names are case-insensitive but cannot contain
    // `\` (it'd be parsed as a sub-key separator). Strip whitespace
    // and any path separator / control char.
    final cleaned = appName.replaceAll(RegExp(r'[\\\/:*?"<>|\x00-\x1f]'), '');
    return cleaned.isEmpty ? 'AgentBuddy' : cleaned;
  }

  @override
  Future<bool> isEnabled() async {
    final result = await Process.run('reg', [
      'query',
      _runKey,
      '/v',
      _valueName,
    ]);
    if (result.exitCode != 0) return false;
    final out = (result.stdout as String).toLowerCase();
    return out.contains(_valueName.toLowerCase());
  }

  @override
  Future<bool?> setEnabled(bool enabled) async {
    if (enabled) {
      final exe = _resolveExecutable();
      // Always wrap in quotes so paths with spaces survive the
      // registry parse on next reboot.
      final quoted = exe.contains(' ') ? '"$exe"' : exe;
      final result = await Process.run('reg', [
        'add',
        _runKey,
        '/v',
        _valueName,
        '/t',
        'REG_SZ',
        '/d',
        quoted,
        '/f',
      ]);
      if (result.exitCode != 0) return null;
      return true;
    } else {
      final result = await Process.run('reg', [
        'delete',
        _runKey,
        '/v',
        _valueName,
        '/f',
      ]);
      // `reg delete` returns 1 when the value isn't present —
      // that's a successful no-op for our purposes.
      if (result.exitCode == 0) return false;
      final stderr = (result.stderr as String).toLowerCase();
      if (stderr.contains('unable to find')) return false;
      return null;
    }
  }
}

// ---------------------------------------------------------------------
// macOS
// ---------------------------------------------------------------------

/// Auto-start via a per-user LaunchAgent plist file. macOS reads
/// any `*.plist` in `~/Library/LaunchAgents/` at login (if the
/// `RunAtLoad` key is set) and launches the listed program. We
/// use the `launchd` mechanism rather than the deprecated
/// `LoginItems` API so this works on every supported macOS
/// version. The plist runs the app as a UI element — i.e. a Dock
/// icon — because Agent Buddy is a GUI app; users have already
/// opted in by enabling the toggle, and launching headless
/// wouldn't show them anything useful.
class MacAutostartService implements AutostartService {
  MacAutostartService({
    String appName = 'Agent Buddy',
    String bundleId = 'com.agentbuddy.app',
    String? executablePathOverride,
    String? homeDirectoryOverride,
  }) : _appName = appName,
       _bundleId = _sanitizeBundleId(bundleId),
       _executablePathOverride = executablePathOverride,
       _homeDirectoryOverride = homeDirectoryOverride;

  final String _appName;
  final String _bundleId;
  final String? _executablePathOverride;
  final String? _homeDirectoryOverride;

  @override
  bool get isSupported => true;

  Directory _launchAgentsDir() {
    final home =
        _homeDirectoryOverride ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return Directory(p.join(home, 'Library', 'LaunchAgents'));
  }

  File _plistFile() {
    return File(p.join(_launchAgentsDir().path, '$_bundleId.plist'));
  }

  String _resolveExecutable() {
    final override = _executablePathOverride;
    if (override != null && override.isNotEmpty) return override;
    return Platform.resolvedExecutable;
  }

  static String _sanitizeBundleId(String id) {
    // launchd labels use reverse-DNS; allow letters / digits /
    // `.` / `-` and substitute `_` for anything else. Empty
    // string → sensible default.
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9.\-]'), '_');
    return cleaned.isEmpty ? 'com.agentbuddy.app' : cleaned;
  }

  @override
  Future<bool> isEnabled() async {
    final f = _plistFile();
    return f.exists();
  }

  @override
  Future<bool?> setEnabled(bool enabled) async {
    final file = _plistFile();
    if (!enabled) {
      if (!await file.exists()) return false;
      try {
        await file.delete();
        return false;
      } catch (_) {
        return null;
      }
    }
    try {
      final dir = _launchAgentsDir();
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      final exe = _resolveExecutable();
      // Hand-rolled XML — avoids pulling in an XML dependency for
      // a 12-line static document.
      final plist =
          '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$_bundleId</string>
    <key>ProgramArguments</key>
    <array>
        <string>${_xmlEscape(exe)}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/$_bundleId.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/$_bundleId.err.log</string>
    <key>Comment</key>
    <string>${_xmlEscape(_appName)} auto-start</string>
</dict>
</plist>
''';
      await file.writeAsString(plist);
      return true;
    } catch (_) {
      return null;
    }
  }
}

String _xmlEscape(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

// ---------------------------------------------------------------------
// Linux
// ---------------------------------------------------------------------

/// Auto-start via an XDG-compliant `.desktop` entry in
/// `~/.config/autostart/`. Modern desktop environments (GNOME,
/// KDE, XFCE, Cinnamon, MATE, …) honour this directory out of
/// the box. We emit a minimal entry — `Type`, `Name`, `Exec`,
/// `Terminal=false`, `X-GNOME-Autostart-enabled=true` (the
/// last one is the GNOME-3 way to mark the entry as active, and
/// is harmlessly ignored elsewhere). Removing the file
/// un-registers the entry. Per [XDG Autostart spec][1] we do NOT
/// set `Hidden=true` to disable — we just delete the file so the
/// "Show applications" tool lists the entry exactly when it's
/// actually registered.
///
/// [1]: https://specifications.freedesktop.org/autostart-spec/autostart-spec-latest.html
class LinuxAutostartService implements AutostartService {
  LinuxAutostartService({
    String appName = 'Agent Buddy',
    String desktopEntryName = 'agent-buddy',
    String? executablePathOverride,
    String? homeDirectoryOverride,
  }) : _appName = appName,
       _desktopEntryName = _sanitizeDesktopEntryName(desktopEntryName),
       _executablePathOverride = executablePathOverride,
       _homeDirectoryOverride = homeDirectoryOverride;

  final String _appName;
  final String _desktopEntryName;
  final String? _executablePathOverride;
  final String? _homeDirectoryOverride;

  @override
  bool get isSupported => true;

  Directory _autostartDir() {
    // $XDG_CONFIG_HOME wins, fall back to ~/.config (XDG default).
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : (_homeDirectoryOverride ??
              Platform.environment['HOME'] ??
              Directory.systemTemp.path);
    return Directory(p.join(base, 'autostart'));
  }

  File _desktopFile() {
    return File(p.join(_autostartDir().path, '$_desktopEntryName.desktop'));
  }

  String _resolveExecutable() {
    final override = _executablePathOverride;
    if (override != null && override.isNotEmpty) return override;
    return Platform.resolvedExecutable;
  }

  static String _sanitizeDesktopEntryName(String name) {
    // Desktop entry basename: letters / digits / `-` / `_` only.
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9\-_]'), '-');
    return cleaned.isEmpty ? 'agent-buddy' : cleaned;
  }

  @override
  Future<bool> isEnabled() async {
    final f = _desktopFile();
    return f.exists();
  }

  @override
  Future<bool?> setEnabled(bool enabled) async {
    final file = _desktopFile();
    if (!enabled) {
      if (!await file.exists()) return false;
      try {
        await file.delete();
        return false;
      } catch (_) {
        return null;
      }
    }
    try {
      final dir = _autostartDir();
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      final exe = _resolveExecutable();
      final exeLine = exe.contains(' ') ? '"$exe"' : exe;
      final content =
          '''[Desktop Entry]
Type=Application
Name=$_appName
Comment=Auto-start $_appName at login
Exec=$exeLine
Terminal=false
X-GNOME-Autostart-enabled=true
''';
      await file.writeAsString(content);
      return true;
    } catch (_) {
      return null;
    }
  }
}
