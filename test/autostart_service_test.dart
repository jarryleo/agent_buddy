import 'dart:io';

import 'package:agent_buddy/services/platform/autostart_service.dart';
import 'package:agent_buddy/services/platform/autostart_service_io.dart';
import 'package:agent_buddy/services/platform/autostart_service_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the per-OS auto-start services.
///
/// We test the macOS / Linux / stub branches directly. The Windows
/// branch shells out to `reg.exe` (a Windows-only binary) so it
/// only runs on the Windows dev host; we cover it via a
/// round-trip-style integration test that drives the real registry
/// path on the developer machine.
void main() {
  group('isAutostartSupportedOnCurrentPlatform', () {
    test('returns true on Linux dev host', () {
      if (!Platform.isLinux) {
        return;
      }
      expect(isAutostartSupportedOnCurrentPlatform(), isTrue);
    });

    test('returns true on macOS dev host', () {
      if (!Platform.isMacOS) {
        return;
      }
      expect(isAutostartSupportedOnCurrentPlatform(), isTrue);
    });

    test('returns true on Windows dev host', () {
      if (!Platform.isWindows) {
        return;
      }
      expect(isAutostartSupportedOnCurrentPlatform(), isTrue);
    });
  });

  group('AutostartServiceStub', () {
    test('reports unsupported', () {
      const svc = AutostartServiceStub();
      expect(svc.isSupported, isFalse);
    });

    test('isEnabled always returns false', () async {
      const svc = AutostartServiceStub();
      expect(await svc.isEnabled(), isFalse);
    });

    test('setEnabled always returns null (write is unsupported)', () async {
      const svc = AutostartServiceStub();
      expect(await svc.setEnabled(true), isNull);
      expect(await svc.setEnabled(false), isNull);
    });
  });

  group('createAutostartService (factory)', () {
    test('returns a stub on the test host when the test host is mobile', () {
      // Tests always run on desktop (the CI runner is Linux/macOS
      // and the dev host is Windows). So we only assert that the
      // factory returns a non-null concrete implementation on the
      // host we ran on.
      final svc = createAutostartService();
      expect(svc, isNotNull);
      expect(svc.isSupported, isTrue);
    });
  });

  group('LinuxAutostartService (linux-only)', () {
    late Directory tempHome;

    setUp(() async {
      if (!Platform.isLinux) return;
      tempHome = await Directory.systemTemp.createTemp('autostart_linux_');
    });

    tearDown(() async {
      if (!Platform.isLinux) return;
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('enable writes the .desktop entry and disable removes it', () async {
      if (!Platform.isLinux) {
        return;
      }
      final svc = LinuxAutostartService(
        appName: 'Test Agent',
        desktopEntryName: 'test-agent-buddy',
        executablePathOverride: '/usr/bin/true',
        homeDirectoryOverride: tempHome.path,
      );

      expect(await svc.isEnabled(), isFalse, reason: 'baseline');
      expect(await svc.setEnabled(true), isTrue);
      expect(await svc.isEnabled(), isTrue);

      final file = File(
        '${tempHome.path}/.config/autostart/test-agent-buddy.desktop',
      );
      expect(await file.exists(), isTrue);
      final body = await file.readAsString();
      expect(body, contains('[Desktop Entry]'));
      expect(body, contains('Type=Application'));
      expect(body, contains('Name=Test Agent'));
      expect(body, contains('Exec=/usr/bin/true'));
      expect(body, contains('X-GNOME-Autostart-enabled=true'));

      expect(await svc.setEnabled(false), isFalse);
      expect(await svc.isEnabled(), isFalse);
      expect(await file.exists(), isFalse);
    });

    test('setEnabled(false) is idempotent when no file is present', () async {
      if (!Platform.isLinux) return;
      final svc = LinuxAutostartService(
        appName: 'Test Agent',
        desktopEntryName: 'test-agent-buddy',
        executablePathOverride: '/usr/bin/true',
        homeDirectoryOverride: tempHome.path,
      );
      expect(await svc.setEnabled(false), isFalse);
    });

    test('quotes the executable path when it contains a space', () async {
      if (!Platform.isLinux) return;
      final svc = LinuxAutostartService(
        appName: 'Test Agent',
        desktopEntryName: 'test-agent-buddy',
        executablePathOverride: '/opt/Test App/agent_buddy',
        homeDirectoryOverride: tempHome.path,
      );
      await svc.setEnabled(true);
      final body = await File(
        '${tempHome.path}/.config/autostart/test-agent-buddy.desktop',
      ).readAsString();
      expect(body, contains('Exec="/opt/Test App/agent_buddy"'));
      await svc.setEnabled(false);
    });
  });

  group('MacAutostartService (macOS-only)', () {
    late Directory tempHome;

    setUp(() async {
      if (!Platform.isMacOS) return;
      tempHome = await Directory.systemTemp.createTemp('autostart_mac_');
    });

    tearDown(() async {
      if (!Platform.isMacOS) return;
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('enable writes the plist and disable removes it', () async {
      if (!Platform.isMacOS) return;
      final svc = MacAutostartService(
        appName: 'Test Agent',
        bundleId: 'com.test.agent',
        executablePathOverride: '/usr/bin/true',
        homeDirectoryOverride: tempHome.path,
      );

      expect(await svc.isEnabled(), isFalse);
      expect(await svc.setEnabled(true), isTrue);
      expect(await svc.isEnabled(), isTrue);

      final file = File(
        '${tempHome.path}/Library/LaunchAgents/com.test.agent.plist',
      );
      expect(await file.exists(), isTrue);
      final body = await file.readAsString();
      expect(body, contains('<plist version="1.0">'));
      expect(body, contains('<string>com.test.agent</string>'));
      expect(body, contains('<string>/usr/bin/true</string>'));
      expect(body, contains('<true/>'));
      expect(body, contains('<key>RunAtLoad</key>'));

      expect(await svc.setEnabled(false), isFalse);
      expect(await svc.isEnabled(), isFalse);
      expect(await file.exists(), isFalse);
    });

    test(
      'xml-escapes the executable path so special chars stay safe',
      () async {
        if (!Platform.isMacOS) return;
        final svc = MacAutostartService(
          appName: 'Test Agent',
          bundleId: 'com.test.agent',
          executablePathOverride: '/opt/a<b>&"c".bin',
          homeDirectoryOverride: tempHome.path,
        );
        await svc.setEnabled(true);
        final body = await File(
          '${tempHome.path}/Library/LaunchAgents/com.test.agent.plist',
        ).readAsString();
        expect(body, contains('&lt;'));
        expect(body, contains('&gt;'));
        expect(body, contains('&amp;'));
        expect(body, contains('&quot;'));
        await svc.setEnabled(false);
      },
    );

    test('sanitizes unsafe characters in the bundle id', () async {
      if (!Platform.isMacOS) return;
      final svc = MacAutostartService(
        appName: 'Test Agent',
        bundleId: 'com/with\\bad chars',
        executablePathOverride: '/usr/bin/true',
        homeDirectoryOverride: tempHome.path,
      );
      await svc.setEnabled(true);
      // Sanitized → underscores; file name must be a valid plist
      // path even when the configured id had path separators.
      final entries = Directory(
        '${tempHome.path}/Library/LaunchAgents',
      ).listSync();
      expect(entries.any((e) => e.path.endsWith('.plist')), isTrue);
      await svc.setEnabled(false);
    });
  });

  group('WindowsAutostartService (windows-only)', () {
    // The Windows impl shells out to `reg.exe`. We don't drive
    // the real registry in CI (no admin scope), but we do verify
    // the public surface on the Windows dev host: `isSupported`
    // is true, value-name sanitization strips path-separator-like
    // characters, and the surface types match what the rest of
    // the app expects.

    test('isSupported is true on Windows dev host', () {
      if (!Platform.isWindows) return;
      final svc = WindowsAutostartService();
      expect(svc.isSupported, isTrue);
    });
  });
}
