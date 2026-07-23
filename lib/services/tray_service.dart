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
  /// and write an ICO next to the executable. The path handed back
  /// is a relative `../../agent_buddy_tray.ico` so the OS resolves
  /// it to the same directory as the executable at runtime.
  Future<String> _prepareTrayIcon() async {
    final pngBytes = await rootBundle.load('assets/icon/ic_app.png');
    final decoded = img.decodePng(pngBytes.buffer.asUint8List());
    if (decoded == null) {
      // If decoding fails, fall back to the PNG. Windows will skip
      // the icon but the rest of the tray affordance still works.
      return 'assets/icon/ic_app.png';
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
        return 'assets/icon/ic_app.png';
      }
    }

    // The tray_manager joins `iconPath` onto
    // `<exeDir>/data/flutter_assets/`. Two `..` walks back out of
    // `data/flutter_assets` to land on `<exeDir>`, where the file
    // actually lives.
    return p.join('..', '..', 'agent_buddy_tray.ico');
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
      try {
        await trayManager.destroy().timeout(const Duration(milliseconds: 150));
      } catch (_) {}
      exit(0);
    }());
  }
}
