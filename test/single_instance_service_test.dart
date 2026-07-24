import 'dart:io';

import 'package:agent_buddy/services/single_instance_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the wire-level lock + signal protocol used by the
/// `SingleInstanceService`. The service only depends on `dart:io`'s
/// `ServerSocket`, so we can drive it directly in `flutter test`
/// without touching the `window_manager` plugin (the show handler is
/// injected as a closure).
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('single_instance_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String lockFilePath() =>
      '${tempDir.path}${Platform.pathSeparator}instance.lock';

  group('SingleInstanceService.acquire', () {
    test('first acquire on a fresh lock file succeeds', () async {
      final svc = SingleInstanceService.forTest(lockFilePath: lockFilePath());
      addTearDown(svc.dispose);
      final ok = await svc.acquire();
      expect(ok, isTrue);
      expect(svc.isHolding, isTrue);
      expect(svc.listeningPort, isNotNull);
      expect(
        await File(lockFilePath()).readAsString(),
        contains('${svc.listeningPort}'),
      );
    });

    test('second acquire against a still-alive primary fails', () async {
      final lock = lockFilePath();
      final primary = SingleInstanceService.forTest(lockFilePath: lock);
      final secondary = SingleInstanceService.forTest(lockFilePath: lock);
      addTearDown(() async {
        await primary.dispose();
        await secondary.dispose();
      });
      expect(await primary.acquire(), isTrue);
      expect(await secondary.acquire(), isFalse);
      expect(primary.isHolding, isTrue);
      expect(secondary.isHolding, isFalse);
    });

    test('acquire is idempotent inside the same process', () async {
      final svc = SingleInstanceService.forTest(lockFilePath: lockFilePath());
      addTearDown(svc.dispose);
      expect(await svc.acquire(), isTrue);
      // A second call must NOT rebind or rewrite the lock file —
      // the pet-window sub-engine inside the same OS process shares
      // the primary's lock without re-acquiring it.
      final originalPort = svc.listeningPort;
      final lockContentsBefore = await File(lockFilePath()).readAsString();
      expect(await svc.acquire(), isTrue);
      expect(svc.listeningPort, originalPort);
      expect(await File(lockFilePath()).readAsString(), lockContentsBefore);
    });

    test('stale lock file is detected and replaced', () async {
      // Write a file pointing at a port nothing listens on —
      // simulates a primary that crashed without cleaning up.
      final lock = lockFilePath();
      await File(lock).writeAsString('1\n');
      final svc = SingleInstanceService.forTest(
        lockFilePath: lock,
        probeTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(svc.dispose);
      final ok = await svc.acquire();
      expect(ok, isTrue);
      // The replacement lock file should now record *our* port —
      // not the stale "1".
      final recorded = await File(lock).readAsString();
      expect(int.tryParse(recorded.trim()), svc.listeningPort);
      expect(svc.listeningPort, isNot(1));
    });

    test('dispose releases the lock so a later acquire succeeds', () async {
      final lock = lockFilePath();
      final primary = SingleInstanceService.forTest(lockFilePath: lock);
      expect(await primary.acquire(), isTrue);
      await primary.dispose();
      expect(primary.isHolding, isFalse);
      expect(await File(lock).exists(), isFalse);

      final next = SingleInstanceService.forTest(lockFilePath: lock);
      addTearDown(next.dispose);
      expect(await next.acquire(), isTrue);
      expect(next.isHolding, isTrue);
    });
  });

  group('SingleInstanceService.sendShowToExisting', () {
    test('returns false when no lock file exists', () async {
      final secondary = SingleInstanceService.forTest(
        lockFilePath: lockFilePath(),
      );
      addTearDown(secondary.dispose);
      final sent = await secondary.sendShowToExisting();
      expect(sent, isFalse);
    });

    test('returns true after a primary acquires the lock', () async {
      final lock = lockFilePath();
      final primary = SingleInstanceService.forTest(lockFilePath: lock);
      final secondary = SingleInstanceService.forTest(lockFilePath: lock);
      addTearDown(() async {
        await primary.dispose();
        await secondary.dispose();
      });
      expect(await primary.acquire(), isTrue);

      var calls = 0;
      primary.setOnShowRequested(() async {
        calls++;
      });

      final sent = await secondary.sendShowToExisting();
      expect(sent, isTrue);
      // Allow the server callback to run on the event loop.
      await _pump();
      expect(calls, 1);
    });

    test(
      'unknown commands are ignored without breaking the SHOW handler',
      () async {
        final lock = lockFilePath();
        final primary = SingleInstanceService.forTest(lockFilePath: lock);
        final secondary = SingleInstanceService.forTest(lockFilePath: lock);
        addTearDown(() async {
          await primary.dispose();
          await secondary.dispose();
        });
        expect(await primary.acquire(), isTrue);

        var showCalls = 0;
        primary.setOnShowRequested(() async {
          showCalls++;
        });

        // Open a raw socket on the primary's recorded port and
        // stream garbage + SHOW — the service must drop the first
        // and dispatch the second.
        final port = primary.listeningPort!;
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 1),
        );
        socket.add('GARBAGE\nSHOW\n'.codeUnits);
        await socket.flush();
        await socket.close();
        await _pump();

        expect(showCalls, 1);
      },
    );
  });

  group('SingleInstanceService.setOnShowRequested', () {
    test('SHOW commands arriving before the handler is wired are buffered '
        'and replayed on registration', () async {
      final lock = lockFilePath();
      final primary = SingleInstanceService.forTest(lockFilePath: lock);
      final secondary = SingleInstanceService.forTest(lockFilePath: lock);
      addTearDown(() async {
        await primary.dispose();
        await secondary.dispose();
      });
      expect(await primary.acquire(), isTrue);
      expect(primary.isWindowReady, isFalse);

      final sent = await secondary.sendShowToExisting();
      expect(sent, isTrue);
      await _pump();

      // The primary has not wired its handler yet — the SHOW must
      // be queued instead of lost.
      var calls = 0;
      primary.setOnShowRequested(() async {
        calls++;
      });
      // `setOnShowRequested` should replay the pending command in
      // arrival order, so we observe exactly one call.
      await _pump();
      expect(calls, 1);
      expect(primary.isWindowReady, isTrue);
    });

    test('post-ready SHOW commands fire the handler immediately', () async {
      final primary = SingleInstanceService.forTest(
        lockFilePath: lockFilePath(),
      );
      addTearDown(primary.dispose);
      expect(await primary.acquire(), isTrue);
      var calls = 0;
      primary.setOnShowRequested(() async {
        calls++;
      });
      await _pump();
      expect(calls, 0, reason: 'no traffic, no calls');

      // Send SHOW via a raw socket using the primary's recorded
      // port; the bundled second-instance helper also needs a
      // lock file, so going raw keeps the test self-contained.
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        primary.listeningPort!,
        timeout: const Duration(seconds: 1),
      );
      socket.add('SHOW\n'.codeUnits);
      await socket.flush();
      await socket.close();
      await _pump();
      expect(calls, 1);
    });

    test('handler exceptions do not break the dispatch loop', () async {
      final primary = SingleInstanceService.forTest(
        lockFilePath: lockFilePath(),
      );
      addTearDown(primary.dispose);
      expect(await primary.acquire(), isTrue);
      var boomCalls = 0;
      var goodCalls = 0;
      primary.setOnShowRequested(() async {
        boomCalls++;
        throw StateError('window manager unplugged');
      });
      // First SHOW — handler throws; the service swallows and keeps
      // listening.
      final s1 = await Socket.connect(
        InternetAddress.loopbackIPv4,
        primary.listeningPort!,
        timeout: const Duration(seconds: 1),
      );
      s1.add('SHOW\n'.codeUnits);
      await s1.flush();
      await s1.close();
      await _pump();
      expect(boomCalls, 1);

      // Replace the handler with a clean one and re-fire — the
      // listener must still be alive.
      primary.setOnShowRequested(() async {
        goodCalls++;
      });
      final s2 = await Socket.connect(
        InternetAddress.loopbackIPv4,
        primary.listeningPort!,
        timeout: const Duration(seconds: 1),
      );
      s2.add('SHOW\n'.codeUnits);
      await s2.flush();
      await s2.close();
      await _pump();
      expect(goodCalls, 1);
    });
  });
}

/// Drains the microtask queue so listener callbacks fired by the
/// `ServerSocket` have a chance to run. Equivalent to a single
/// `Future.delayed(Duration.zero)` but explicit about intent.
Future<void> _pump() => Future<void>.delayed(Duration.zero);
