import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
import '../l10n/app_localizations_en.dart';
import '../providers/settings_provider.dart';
import '../services/tools/tool_base.dart' show isDesktop;

/// Cross-platform system-tray icon + context menu.
///
/// The main window's close button is intercepted (see
/// `_setupDesktopWindow` in `main.dart`) so clicking it only hides
/// the window — the app keeps running with the desktop pet visible
/// in the background. The tray icon is the only way to bring the
/// main window back or to fully exit the app.
///
/// Desktop only; on mobile / web `initialize()` is a no-op.
class TrayService with TrayListener {
  TrayService({required this.settings});

  final SettingsProvider settings;

  bool _initialized = false;
  bool _exiting = false;
  Timer? _menuRebuildTimer;
  AppLocalizations? _lastL10n;
  bool? _lastShowDesktopPet;

  /// Optional hook fired at the *start* of `_exitApp()`. Wired by
  /// the agent app (in `main.dart`) once the `PetWindowController`
  /// is constructed so the tray menu's "Exit" entry can ask any
  /// live pet sub-window to close itself before terminating the
  /// OS process.
  ///
  /// **Why this matters:** the pet window is implemented as a
  /// separate `flutter::FlutterViewController` inside the same
  /// Windows OS process (see `desktop_multi_window` 0.3
  /// `multi_window_manager.cc`). When the main isolate calls
  /// `dart:io`'s `exit(0)`, the C runtime is expected to invoke
  /// `TerminateProcess`, but the embedding layer's plugin
  /// teardown (Flutter engine + `window_manager` channels
  /// flushing) can race the termination and leave the pet's
  /// HWND alive in the OS process. Across repeated
  /// exit-then-launch cycles this compounds — each launch saw
  /// a stranded sub-engine from the previous run. Asking the
  /// pet window to close itself via the same IPC channel it
  /// already exposes (`closePetWindow`) drains those channels
  /// synchronously before we terminate.
  Future<void> Function()? _onExitRequested;

  /// Wired by the agent app once a `PetWindowController` has
  /// been built. Idempotent — passing multiple handlers
  /// replaces (does not stack) the previous one.
  void setOnExitRequested(Future<void> Function() handler) {
    _onExitRequested = handler;
  }

  /// Set up the tray icon, context menu, and listener. Idempotent.
  Future<void> initialize() async {
    if (_initialized) return;
    if (!isDesktop()) return;
    _initialized = true;

    try {
      final iconPath = await _prepareTrayIcon();
      await trayManager.setIcon(iconPath);
    } on MissingPluginException {
      // Plugin not registered (e.g. in a unit-test harness). Treat
      // the tray as unavailable rather than crashing startup.
      return;
    } catch (e) {
      debugPrint('Failed to prepare tray icon: $e');
      return;
    }

    try {
      await trayManager.setToolTip('Agent Buddy');
    } catch (_) {}

    await _rebuildMenuIfLabelsChanged();
    trayManager.addListener(this);
    settings.addListener(_onSettingsChanged);
  }

  /// tray_manager's Windows side calls `LoadImage(..., IMAGE_ICON,
  /// ..., LR_LOADFROMFILE)`, which only accepts ICO files. The
  /// bundled asset is a 1024×1024 PNG, so we resize it to 32 px
  /// and write an ICO next to the executable.
  ///
  /// The path we hand back MUST be absolute. `LoadImage` resolves
  /// relative paths against the *process's current working
  /// directory*, not the executable's directory — and Windows sets
  /// CWD to whatever the launcher gave it (the install dir for a
  /// fresh launch, the Start-Menu shortcut's "Start in" for a
  /// Start-Menu launch, and the **captured CWD at pin time** for a
  /// pinned-taskbar launch — none of which is reliably
  /// `<exeDir>/data/flutter_assets/`). The previous relative
  /// `../../agent_buddy_tray.ico` only worked when CWD happened
  /// to be that folder; after a reinstall that produced a blank
  /// shell-notify call and the tray icon vanished.
  Future<String> _prepareTrayIcon() async {
    final pngBytes = await rootBundle.load('assets/icon/ic_app.png');
    final decoded = img.decodePng(pngBytes.buffer.asUint8List());
    if (decoded == null) {
      // If decoding fails, fall back to the asset path. Windows
      // will skip the icon but the rest of the tray affordance
      // still works (left-click menu etc. survive a missing icon).
      return p.join('assets', 'icon', 'ic_app.png');
    }

    final resized = img.copyResize(decoded, width: 32, height: 32);
    final icoBytes = img.encodeIco(resized);

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final iconFile = File(p.join(exeDir, 'agent_buddy_tray.ico'));
    if (!await iconFile.exists()) {
      try {
        await iconFile.writeAsBytes(icoBytes);
      } catch (e) {
        debugPrint('Failed to write tray icon to $iconFile: $e');
        return p.join('assets', 'icon', 'ic_app.png');
      }
    }

    // Absolute path — survives every Windows launcher (fresh
    // exe, Start-Menu shortcut, pinned taskbar shortcut, autostart
    // registry entry, `cmd.exe` launch …) because it doesn't
    // depend on whoever set CWD.
    return iconFile.path;
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    settings.removeListener(_onSettingsChanged);
    trayManager.removeListener(this);
    _menuRebuildTimer?.cancel();
    _menuRebuildTimer = null;
    try {
      await trayManager.destroy();
    } catch (_) {}
    _initialized = false;
  }

  void _onSettingsChanged() {
    if (_exiting) return;
    // Debounce so a burst of `notifyListeners()` (e.g. the locale
    // flip + theme reload) only triggers one menu rebuild.
    _menuRebuildTimer?.cancel();
    _menuRebuildTimer = Timer(const Duration(milliseconds: 100), () {
      // Locale-aware rebuild — only swap the menu when the labels
      // actually changed, otherwise the OS often tears down the
      // native menu and re-creates it for no reason.
      _rebuildMenuIfLabelsChanged();
    });
  }

  Future<void> _rebuildMenuIfLabelsChanged() async {
    final l10n = await _loadL10n();
    final showDesktopPet = settings.showDesktopPet;
    if (identical(l10n, _lastL10n) && showDesktopPet == _lastShowDesktopPet) {
      return;
    }
    _lastL10n = l10n;
    _lastShowDesktopPet = showDesktopPet;
    await _rebuildMenu(l10n, showDesktopPet);
  }

  Future<AppLocalizations> _loadL10n() async {
    final code = settings.localeCode;
    final locale = (code == 'system' || code.isEmpty) ? null : Locale(code);
    if (locale == null) {
      return AppLocalizationsEn(const Locale('en').toString());
    }
    return AppLocalizations.delegate.load(locale);
  }

  Future<void> _rebuildMenu(AppLocalizations l10n, bool showPet) async {
    final menu = Menu(
      items: [
        MenuItem(key: 'show_main', label: l10n.trayShowMain),
        MenuItem(
          key: 'toggle_pet',
          label: showPet ? l10n.trayHidePet : l10n.trayShowPet,
        ),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: l10n.trayExit),
      ],
    );
    try {
      await trayManager.setContextMenu(menu);
    } catch (_) {}
  }

  // TrayListener — left-click on the tray icon shows the main window.
  // Right-click (down + up) just fires an event; the native plugin
  // never calls `TrackPopupMenu` on its own, so we have to ask for
  // the popup ourselves to get the right-click menu.
  @override
  void onTrayIconMouseDown() {
    _showMainWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    _showContextMenu();
  }

  @override
  void onTrayIconRightMouseUp() {
    _showContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_main':
        _showMainWindow();
      case 'toggle_pet':
        _togglePet();
      case 'exit':
        _exitApp();
    }
  }

  void _showMainWindow() {
    unawaited(() async {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }());
  }

  void _showContextMenu() {
    unawaited(() async {
      try {
        await trayManager.popUpContextMenu();
      } catch (_) {}
    }());
  }

  void _togglePet() {
    unawaited(settings.setShowDesktopPet(!settings.showDesktopPet));
  }

  void _exitApp() {
    if (_exiting) return;
    _exiting = true;
    _menuRebuildTimer?.cancel();
    _menuRebuildTimer = null;

    unawaited(() async {
      // Step 1 — best-effort pet window teardown. The pet sub-window
      // is a separate Flutter engine in the same OS process (see
      // `_onExitRequested`'s doc-comment). Closing it before we
      // terminate drains its plugin channels so the embedding
      // layer isn't trying to flush IPC traffic into a half-dead
      // engine when `exit(0)` finally runs. Without this, a
      // hard-killed pet HWND can survive past the main window
      // and remain visible in Task Manager long after the tray
      // icon disappears — which is exactly the bug we're fixing.
      final onExit = _onExitRequested;
      if (onExit != null) {
        try {
          await onExit().timeout(const Duration(milliseconds: 800));
        } catch (_) {
          // Pet may already be torn down, or its IPC channel may
          // be unresponsive. Fall through to the destructive
          // step below either way.
        }
      }

      // Step 2 — drop the tray icon. Best-effort with a tight
      // timeout so a hung shell-notify call can't extend the
      // shutdown. The tray icon being a hair slower to disappear
      // than the window is acceptable; the OS process must go.
      try {
        await trayManager.destroy().timeout(const Duration(milliseconds: 300));
      } catch (_) {}

      // Step 3 — terminate the Win32 message loop cleanly. Under
      // the hood this is a single `PostQuitMessage(0)` call
      // (see `window_manager-*/windows/window_manager.cpp`,
      // `WindowManager::Destroy`). Once WM_QUIT is in the main
      // thread's message queue, the embedder's `GetMessage`
      // returns 0, `wWinMain` returns `EXIT_SUCCESS`, and the
      // OS process is gone — including every Flutter sub-engine
      // and the pet HWND that still belongs to this process.
      //
      // This is the correct Windows-side way to terminate a
      // Flutter desktop app. `dart:io`'s `exit(0)` alone is
      // unreliable when the engine has sub-windows with their
      // own `FlutterViewController`s: the embedder's plugin
      // teardown can keep the OS thread alive long enough that
      // the process lingers in Task Manager and across the next
      // launch, leaving the user staring at a stranded window.
      try {
        await windowManager.destroy();
      } catch (_) {}

      // Step 4 — belt-and-suspenders fallback for the rare case
      // where `PostQuitMessage` was swallowed by a runaway
      // native message hook. Tiny delay so the Win32 message
      // loop has a chance to drain `WM_QUIT` first; if it
      // doesn't, the C-runtime `exit(0)` does the job.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      exit(0);
    }());
  }
}
