import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../pages/pet_window_page.dart'
    show
        closePetWindow,
        sendPetCancelMove,
        sendPetMoveTo,
        sendPetPlayLooping,
        sendPetPlayOneShot,
        sendPetReset,
        sendPetShowText,
        sendPetSwitch,
        spawnPetWindow;
import '../providers/settings_provider.dart';

typedef PetWindowSpawner = Future<WindowController> Function(String petId);
typedef PetWindowAction = Future<void> Function(WindowController controller);
typedef PetWindowLister = Future<List<WindowController>> Function();

/// Owns the lifecycle of the desktop pet window.
///
/// The settings provider tracks the user's two intents — the
/// master toggle ([SettingsProvider.showDesktopPet]) and the
/// active pet id ([SettingsProvider.activePetId]) — but it knows
/// nothing about Flutter windows. This class subscribes to the
/// provider, and on every change either spawns a fresh pet
/// window, brings the existing one forward, or closes it.
///
/// **Why a singleton and not a `ChangeNotifier` in the provider?**
/// The provider is hot-reloaded frequently during development; a
/// `ChangeNotifier` that owns a sub-engine would have to be
/// carefully torn down on every swap. A free-standing controller
/// that the app owns for its lifetime is simpler and survives
/// hot-reload by being wired up once in `mainApp`.
class PetWindowController {
  PetWindowController({
    required SettingsProvider settings,
    PetWindowSpawner? spawnWindow,
    PetWindowAction? closeWindow,
    PetWindowAction? showWindow,
    PetWindowAction? hideWindow,
    PetWindowLister? listWindows,
    Stream<void>? windowsChanged,
  }) : _settings = settings,
       _spawnWindow = spawnWindow ?? ((petId) => spawnPetWindow(petId: petId)),
       _closeWindowAction = closeWindow ?? closePetWindow,
       _showWindowAction = showWindow ?? ((controller) => controller.show()),
       _hideWindowAction = hideWindow ?? ((controller) => controller.hide()),
       _listWindows = listWindows ?? WindowController.getAll {
    _settings.addListener(_onSettingsChanged);
    _windowsChangedSub = (windowsChanged ?? onWindowsChanged).listen(
      _onWindowsChanged,
    );
  }

  final SettingsProvider _settings;
  final PetWindowSpawner _spawnWindow;
  final PetWindowAction _closeWindowAction;
  final PetWindowAction _showWindowAction;
  final PetWindowAction _hideWindowAction;
  final PetWindowLister _listWindows;

  WindowController? _controller;
  String? _controllerPetId;
  bool _windowVisible = false;
  bool _syncing = false;
  bool _reconcilePending = false;
  bool _disposed = false;
  StreamSubscription<void>? _windowsChangedSub;
  Completer<void>? _windowClosed;
  Timer? _textDispatchTimer;
  String _pendingText = '';

  /// Tear down the sub-window + listener. Called from `mainApp` on
  /// dispose (the app owns this for its lifetime, so it's mostly a
  /// belt-and-suspenders hook for tests).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_onSettingsChanged);
    _textDispatchTimer?.cancel();
    await _closeWindow();
    await _windowsChangedSub?.cancel();
    _windowsChangedSub = null;
  }

  /// Called after the widget tree is up. Performs the initial
  /// reconcile: if the persisted toggle is on and we have a valid
  /// pet id, spawn the window. Idempotent.
  Future<void> syncOnStart() async {
    if (_disposed) return;
    await _reconcile();
  }

  /// Play a one-shot animation (e.g. `jumping` on tool success,
  /// `failed` on tool failure). Silently no-ops when the pet
  /// window isn't currently shown.
  Future<void> playOneShot(String name) async {
    final controller = _controller;
    if (controller == null) return;
    await sendPetPlayOneShot(controller, name);
  }

  /// Switch the pet into a looping animation (e.g. `waiting`
  /// while the user is typing, `review` while the model is
  /// streaming). No-op when the window is hidden.
  Future<void> playLooping(String name) async {
    final controller = _controller;
    if (controller == null) return;
    await sendPetPlayLooping(controller, name);
  }

  /// Drop the pet back to its default animation (typically
  /// `idle`). No-op when the window is hidden.
  Future<void> reset() async {
    final controller = _controller;
    if (controller == null) return;
    await sendPetReset(controller);
  }

  Future<void> showText(String text) async {
    _pendingText = text;
    if (_textDispatchTimer != null) return;
    _textDispatchTimer = Timer(const Duration(milliseconds: 60), () async {
      _textDispatchTimer = null;
      final controller = _controller;
      if (controller == null) return;
      await sendPetShowText(controller, _pendingText);
    });
  }

  /// Tween the pet's window to `(x, y)` at `speed` pixels per
  /// second. The pet window swaps to `run_left` / `run_right`
  /// based on the per-frame delta and falls back to `idle`
  /// once it reaches the target. No-op when the window is
  /// hidden. The director calls this for every "move" entry in
  /// its AI-orchestrated timeline.
  Future<void> moveTo({
    required double x,
    required double y,
    required double speed,
  }) async {
    final controller = _controller;
    if (controller == null) return;
    await sendPetMoveTo(controller, x: x, y: y, speed: speed);
  }

  /// Interrupts an in-flight AI-driven move. The pet stops
  /// where it is and drops back to its default animation. Safe
  /// to call when no move is in flight (the pet window no-ops).
  Future<void> cancelMove() async {
    final controller = _controller;
    if (controller == null) return;
    await sendPetCancelMove(controller);
  }

  Future<void> _onSettingsChanged() async {
    if (_disposed) return;
    await _reconcile();
  }

  Future<void> _onWindowsChanged(void _) async {
    final pendingClose = _windowClosed;
    if (pendingClose != null && !pendingClose.isCompleted) {
      pendingClose.complete();
    }
    if (_disposed) return;
    final controller = _controller;
    if (controller == null) return;
    final windows = await _listWindows();
    if (windows.any((window) => window.windowId == controller.windowId)) return;
    if (!identical(_controller, controller)) return;
    _controller = null;
    _controllerPetId = null;
    _windowVisible = false;
    if (_settings.showDesktopPet) {
      await _settings.setShowDesktopPet(false);
    }
  }

  Future<void> _reconcile() async {
    if (_syncing) {
      _reconcilePending = true;
      return;
    }
    _syncing = true;
    try {
      do {
        _reconcilePending = false;
        await _reconcileCurrentState();
      } while (_reconcilePending && !_disposed);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _reconcileCurrentState() async {
    final wantOpen = _settings.showDesktopPet;
    final petId = _resolvePetId(_settings.activePetId);
    if (!wantOpen) {
      await _hideWindow();
      return;
    }
    if (petId == null) {
      // Toggle on but no pet picked (e.g. fresh install). Close
      // the window — the user has to pick one before anything
      // shows. The settings tab surfaces the empty state.
      await _closeWindow();
      return;
    }
    if (_controllerPetId == petId && _controller != null) {
      if (await _showWindow()) return;
    }
    final controller = _controller;
    if (controller != null && await sendPetSwitch(controller, petId)) {
      _controllerPetId = petId;
      if (await _showWindow()) return;
    }
    await _closeWindow();
    await _spawn(petId);
  }

  String? _resolvePetId(String? raw) {
    if (raw != null && raw.isNotEmpty) return raw;
    // Fall back to the bundled Anya when the user hasn't picked
    // anything yet. We hard-code the id here instead of touching
    // PetService (which would be an awkward layer swap inside
    // the controller). The id is stable across the app's lifetime.
    return 'builtin:anya';
  }

  Future<void> _hideWindow() async {
    final controller = _controller;
    if (controller == null || !_windowVisible) return;
    try {
      await _hideWindowAction(controller);
      if (identical(_controller, controller)) {
        _windowVisible = false;
      }
    } catch (_) {
      await _closeWindow();
    }
  }

  Future<bool> _showWindow() async {
    final controller = _controller;
    if (controller == null) return false;
    if (_windowVisible) return true;
    try {
      await _showWindowAction(controller);
      if (!identical(_controller, controller)) return false;
      _windowVisible = true;
      return true;
    } catch (_) {
      await _closeWindow();
      return false;
    }
  }

  Future<void> _spawn(String petId) async {
    try {
      final controller = await _spawnWindow(petId);
      _controller = controller;
      _controllerPetId = petId;
      _windowVisible = true;
    } catch (e, st) {
      // Spawning can fail on non-desktop targets (e.g. mobile /
      // web) or before the platform plugin is registered.
      // Swallow + log — the settings tab already gates the UI
      // to desktop, so this only fires when something is off
      // about the platform setup.
      debugPrint('Failed to spawn pet window: $e\n$st');
    }
  }

  Future<void> _closeWindow() async {
    final controller = _controller;
    _controller = null;
    _controllerPetId = null;
    _windowVisible = false;
    if (controller == null) return;
    final closed = Completer<void>();
    _windowClosed = closed;
    try {
      await _closeWindowAction(controller);
      await closed.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      if (identical(_windowClosed, closed)) {
        _windowClosed = null;
      }
    } finally {
      if (identical(_windowClosed, closed)) {
        _windowClosed = null;
      }
    }
  }
}

/// `desktop_multi_window` is desktop-only. Calling
/// [PetWindowController] on mobile / web would still try to
/// construct it (no platform channel errors at construction
/// time); the actual spawn call would just throw. We expose this
/// guard so callers can skip the whole sub-tree.
bool petWindowSupportedOnCurrentPlatform() {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
}
