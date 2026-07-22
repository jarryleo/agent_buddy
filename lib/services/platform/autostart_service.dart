import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Top-level predicate mirroring [isDesktop] from
/// `lib/services/tools/tool_base.dart`. Used by the settings UI to
/// gate the auto-start row and by the factory below to pick the
/// right concrete implementation. Web is always excluded (no OS
/// startup-hook on the web).
bool isAutostartSupportedOnCurrentPlatform() {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}

/// Cross-platform "launch at login / auto-start" abstraction.
///
/// Concrete implementations live next to this file:
///   * Windows — registry key under
///     `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
///   * macOS — LaunchAgent plist under
///     `~/Library/LaunchAgents/<bundle>.plist`.
///   * Linux — XDG autostart `.desktop` file under
///     `~/.config/autostart/<name>.desktop`.
///   * Mobile / web — [AutostartServiceStub] that no-ops.
///
/// Implementations are deliberately forgiving: every method returns
/// `false` rather than throwing on platforms where it can't write
/// to the OS-managed store (e.g. a sandboxed macOS app bundle that
/// the user installed but the LaunchAgent dir isn't writable). The
/// settings UI surfaces the result via the caller; the persisted
/// preference still records the user's intent so the toggle keeps
/// its visual state.
abstract class AutostartService {
  /// Whether this implementation can do anything useful on the
  /// current platform. The general-settings tab uses this to hide
  /// the toggle entirely on mobile / web.
  bool get isSupported;

  /// Returns the current auto-start state as the OS sees it. May
  /// drift from the user's stored preference (e.g. the user
  /// disabled it directly via the OS settings app) — the settings
  /// tab reconciles the two by always overwriting the OS state on
  /// toggle.
  Future<bool> isEnabled();

  /// Asks the OS to enable / disable auto-start. Returns the
  /// post-write state as the OS sees it, or `null` when the write
  /// failed and the previous state is preserved. Callers should
  /// roll back the cached preference when `null` comes back so the
  /// toggle's visual state matches reality.
  Future<bool?> setEnabled(bool enabled);
}

/// Injectable factory signature so tests can swap a fake without
/// touching [AutostartServiceFactory].
typedef AutostartServiceBuilder = AutostartService Function();
