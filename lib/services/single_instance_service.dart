import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/tools/tool_base.dart' show isDesktop;

/// Cross-platform single-instance lock + "show me" signal channel.
///
/// The main window's ✕ button is intercepted by `_setupDesktopWindow`
/// (`lib/main.dart`) so closing it only hides the window — the process
/// keeps living in the tray so the desktop pet and any in-flight chat
/// stay alive. Without a single-instance guard, the next shortcut or
/// autostart launch spawns a *second* process which races the original
/// for SharedPreferences / Google Sheets tokens / Hive boxes and
/// frequently renders a blank window while the hidden primary still
/// owns everything.
///
/// This service fixes that race with two pieces:
///
///   1. **Lock file** — `SingleInstanceService` writes its listening
///      port to `<lockFilePath>` (e.g. `agent_buddy.lock` under
///      `getApplicationSupportDirectory()`). Subsequent launches read
///      the file, probe the port via `Socket.connect`, and treat a
///      successful handshake as "primary is alive" (we are the
///      secondary). A stale file left behind by a crashed primary is
///      detected by the connect failing and deleted before becoming
///      the new primary.
///
///   2. **Ephemeral TCP server** — the primary binds
///      `ServerSocket(port: 0, ...)` so the OS picks an unused
///      high-numbered port. Bind-with-zero always succeeds (the OS
///      chooses a free port), sidestepping the cross-process Dart /
///      Winsock quirks we'd hit trying to share a fixed port. The
///      on-disc file is the only source of truth.
///
/// On non-desktop the whole surface is a no-op: `acquire()` returns
/// `true` without touching the filesystem, and `sendShowToExisting`
/// returns `false`.
class SingleInstanceService {
  SingleInstanceService({
    this.lockFilePath,
    this.probeTimeout = const Duration(milliseconds: 800),
    Future<void> Function()? onShowRequested,
  }) : _onShowRequested = onShowRequested;

  /// App-wide singleton (the OS owns at most one primary at a time so
  /// routing through one instance keeps every call site on the same
  /// lock + handler state). Tests construct additional instances via
  /// [SingleInstanceService.forTest].
  static final SingleInstanceService instance = SingleInstanceService();

  /// Test seam — direct construction with overridable knobs.
  @visibleForTesting
  factory SingleInstanceService.forTest({
    String? lockFilePath,
    Duration probeTimeout = const Duration(milliseconds: 800),
    Future<void> Function()? onShowRequested,
  }) =>
      SingleInstanceService(
        lockFilePath: lockFilePath,
        probeTimeout: probeTimeout,
        onShowRequested: onShowRequested,
      );

  /// Where the lock file lives. Production code resolves this once
  /// at startup via `getApplicationSupportDirectory()` and assigns
  /// it back to the singleton; tests point at a
  /// `Directory.systemTemp` file that's cleaned up between cases.
  String? lockFilePath;

  /// How long `sendShowToExisting` / the in-`acquire` probe waits
  /// for the primary's TCP socket before declaring it dead.
  final Duration probeTimeout;

  Future<void> Function()? _onShowRequested;

  ServerSocket? _server;
  File? _lockFile;
  bool _windowReady = false;
  final List<String> _pendingCommands = [];

  /// The port we most recently probed via [_tryConnect]. Captured
  /// by [acquire] for the diagnostic log lines so the operator can
  /// see "port X no longer responds" without having to re-derive
  /// it from the lock file.
  int? _lastProbedPort;

  /// The wire command sent by a second instance to ask the primary
  /// to raise its window. Line-oriented — the handler splits on
  /// newlines so future commands can ride the same socket without
  /// protocol churn.
  static const String showCommand = 'SHOW';

  /// True once [acquire] succeeded — the process is the primary.
  bool get isHolding => _server != null;

  /// True once [setOnShowRequested] has wired the dispatch handler.
  /// Useful for tests and for callers that want to know whether a
  /// direct `onShowRequested?.call()` will fire instead of buffering.
  bool get isWindowReady => _windowReady;

  /// Returns the OS-assigned port the server is bound to. `null`
  /// when [acquire] has not been called yet (or on a non-primary
  /// stub instance).
  int? get listeningPort => _server?.port;

  /// Try to claim the single-instance lock. Returns `true` if the
  /// current process is now the primary; `false` if another instance
  /// owns the lock and the caller should [sendShowToExisting] + exit.
  ///
  /// No-op on non-desktop (no port is bound; no file written;
  /// always returns `true`) so mobile / web boot-paths stay
  /// untouched.
  ///
  /// Idempotent: calling it twice in the same process returns `true`
  /// without rebinding or re-writing the lock file.
  Future<bool> acquire() async {
    if (!isDesktop()) return true;
    if (_server != null) return true;

    // Step 1: if a previous primary left a lock file, probe the
    // recorded port to see if it's still alive.
    if (lockFilePath != null) {
      final lockFile = File(lockFilePath!);
      final primaryAlive = await _isPrimaryAlive(lockFile);
      if (primaryAlive == true) {
        debugPrint('SingleInstanceService: primary is alive at '
            'port $_lastProbedPort — becoming secondary.');
        return false;
      }
      // `false` (stale lock deleted best-effort) and `null` (no
      // file at all) both fall through to "become the new primary".
      // We log the outcome so a future "two windows opened after
      // pinned-taskbar click" bug has something to bisect with.
      if (primaryAlive == false) {
        debugPrint('SingleInstanceService: stale lock file at '
            '$lockFilePath (port $_lastProbedPort no longer '
            'responds) — reclaiming.');
      }
    }

    // Step 2: become the primary. `port: 0` lets the OS pick an
    // unused high-numbered port for us, so we never collide with
    // anything that didn't go through this same mechanism.
    try {
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        // Default — no SO_REUSEADDR. We never need to share a port
        // because every primary owns its own ephemeral one, and
        // allowing SO_REUSEADDR on Windows would let an
        // attacker / second primary piggy-back on the same port.
      );
      server.listen(
        _handleClient,
        onError: (Object error, StackTrace stack) =>
            _onServerError(error, stack),
        cancelOnError: false,
      );
      _server = server;

      if (lockFilePath != null) {
        final file = File(lockFilePath!);
        try {
          await file.parent.create(recursive: true);
          // Write atomically via a sidecar then rename, so a
          // racing read never sees a partially written file.
          final temp = File('$lockFilePath.tmp');
          await temp.writeAsString('${server.port}\n');
          await temp.rename(lockFilePath!);
          _lockFile = file;
        } catch (e) {
          // The lock file is advisory — losing the write must not
          // crash startup. We fall back to "primary holds the
          // socket" semantics; subsequent launches with no file
          // will both succeed, but that's a benign regression
          // (two parallel primaries is at worst wasteful).
          debugPrint('SingleInstanceService: failed to write lock file: $e');
        }
      }
      return true;
    } on SocketException catch (e) {
      // Shouldn't happen for port: 0, but log defensively.
      debugPrint('SingleInstanceService: port:0 bind failed: $e');
      return false;
    } on Object catch (e, st) {
      debugPrint('SingleInstanceService: bind failed: $e\n$st');
      return false;
    }
  }

  /// Second-instance API: ping the primary and ask it to come
  /// forward. Returns `true` if the SHOW command was delivered; the
  /// caller is expected to follow up with `exit(0)` either way.
  ///
  /// The lock file is the source of truth for the primary's port;
  /// we read it, probe, and dispatch.
  Future<bool> sendShowToExisting({Duration? timeout}) async {
    if (lockFilePath == null) return false;
    final lockFile = File(lockFilePath!);
    int? port = await _readPort(lockFile);
    if (port == null || port <= 0) return false;
    var socket = await _tryConnect(port, timeout: timeout);
    if (socket == null) {
      // The first probe raced with the primary tearing down (or
      // the file is now freshly-rewritten by a brand-new primary).
      // Re-read + retry once before giving up.
      port = await _readPort(lockFile);
      if (port == null || port <= 0) return false;
      socket = await _tryConnect(port, timeout: timeout);
      if (socket == null) return false;
    }
    try {
      socket.add(utf8.encode('$showCommand\n'));
      await socket.flush();
      await socket.close();
    } catch (_) {}
    return true;
  }

  /// Register the "raise the main window" callback. Called from
  /// production code inside `windowManager.waitUntilReadyToShow` so
  /// the `window_manager` plugin is fully initialised before we try
  /// to use it.
  ///
  /// Any commands buffered before this call (e.g. a SHOW that
  /// arrived during Flutter's startup) get replayed in arrival
  /// order. Idempotent: registering a new handler replaces the
  /// old one without double-dispatch.
  void setOnShowRequested(Future<void> Function() handler) {
    _onShowRequested = handler;
    _windowReady = true;
    final pending = List<String>.from(_pendingCommands);
    _pendingCommands.clear();
    for (final cmd in pending) {
      _dispatch(cmd);
    }
  }

  /// Tear the lock down. Called from production at graceful exit
  /// (so the next launch doesn't have to detect a stale file) and
  /// from tests between cases.
  Future<void> dispose() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {}
    }
    final file = _lockFile ?? (lockFilePath != null ? File(lockFilePath!) : null);
    _lockFile = null;
    if (file != null) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
    _windowReady = false;
    _pendingCommands.clear();
  }

  /// Reads the lock file and probes the recorded port.
  ///
  /// Returns `true` when the primary responded to a TCP connect
  /// (we are the second instance), `false` when the primary is
  /// dead (file deleted best-effort, fall through to become the
  /// new primary), or `null` when no lock file exists at all
  /// (clean cold start).
  Future<bool?> _isPrimaryAlive(File lockFile) async {
    if (!await lockFile.exists()) return null;
    final port = await _readPort(lockFile);
    if (port == null) {
      // Unreadable lock file — treat as stale and replace.
      try {
        await lockFile.delete();
      } catch (_) {}
      return false;
    }
    _lastProbedPort = port;
    // Two probes back-to-back. The first TCP `connect()` to a
    // 127.0.0.1 port that the OS just brought up can occasionally
    // race the listening side's accept queue and time out (we hit
    // this on a Windows-11 box where the pinned-taskbar launch
    // fires `_setupDesktopWindow` *very* shortly after the user
    // clicked the icon — milliseconds after the primary's lock
    // file landed). A second probe covers that without making the
    // "primary is dead" path noticeably slower.
    var probe = await _tryConnect(port);
    if (probe == null) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      probe = await _tryConnect(port);
    }
    if (probe != null) {
      try {
        await probe.close();
      } catch (_) {}
      return true;
    }
    // Stale lock — replace it.
    try {
      await lockFile.delete();
    } catch (_) {}
    return false;
  }

  Future<int?> _readPort(File lockFile) async {
    try {
      if (!await lockFile.exists()) return null;
      final raw = await lockFile.readAsString();
      return int.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
  }

  Future<Socket?> _tryConnect(int port, {Duration? timeout}) async {
    final effective = timeout ?? probeTimeout;
    try {
      return await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: effective,
      );
    } on SocketException {
      return null;
    } on Object catch (_) {
      return null;
    }
  }

  void _handleClient(Socket client) {
    client.listen(
      (data) {
        final text = String.fromCharCodes(data).trim();
        if (text.isEmpty) return;
        for (final line in text.split(RegExp(r'[\r\n]+'))) {
          final cmd = line.trim();
          if (cmd.isEmpty) continue;
          if (cmd == showCommand) {
            _dispatch(cmd);
          } else {
            debugPrint('SingleInstanceService: ignored unknown command "$cmd"');
          }
        }
      },
      onError: (Object _) {},
      onDone: () {
        try {
          client.close();
        } catch (_) {}
      },
      cancelOnError: true,
    );
  }

  void _onServerError(Object error, StackTrace stack) {
    debugPrint('SingleInstanceService server error: $error\n$stack');
  }

  void _dispatch(String cmd) {
    final handler = _onShowRequested;
    if (handler == null || !_windowReady) {
      // Window not ready yet (Flutter / window_manager still
      // booting). Buffer the command — `setOnShowRequested` will
      // replay it once the handler is wired.
      _pendingCommands.add(cmd);
      return;
    }
    if (cmd != showCommand) return;
    unawaited(() async {
      try {
        await handler();
      } on Object catch (e) {
        debugPrint('SingleInstanceService: show handler failed: $e');
      }
    }());
  }
}
