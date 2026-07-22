import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../pages/pet_window_page.dart'
    show closePetWindow, sendPetPlayLooping, sendPetPlayOneShot, sendPetReset, spawnPetWindow;
import '../providers/settings_provider.dart';

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
  PetWindowController({required SettingsProvider settings})
      : _settings = settings {
    _settings.addListener(_onSettingsChanged);
    _windowsChangedSub = onWindowsChanged.listen(_onWindowsChanged);
  }

  final SettingsProvider _settings;

  WindowController? _controller;
  String? _controllerPetId;
  bool _syncing = false;
  bool _disposed = false;
  StreamSubscription<void>? _windowsChangedSub;

  /// Tear down the sub-window + listener. Called from `mainApp` on
  /// dispose (the app owns this for its lifetime, so it's mostly a
  /// belt-and-suspenders hook for tests).
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_onSettingsChanged);
    await _windowsChangedSub?.cancel();
    _windowsChangedSub = null;
    await _closeWindow();
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

  Future<void> _onSettingsChanged() async {
    if (_disposed) return;
    await _reconcile();
  }

  void _onWindowsChanged(void _) {
    if (_disposed) return;
    if (_controller == null) return;
    // The user closed the window via the X / OS chrome. The
    // controller we still hold is stale; null it out so the next
    // reconcile either respawns or stays closed depending on the
    // toggle.
    _controller = null;
    _controllerPetId = null;
    if (_settings.showDesktopPet) {
      // Flip the toggle off so the UI matches reality.
      _settings.setShowDesktopPet(false);
    }
  }

  Future<void> _reconcile() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final wantOpen = _settings.showDesktopPet;
      final petId = _resolvePetId(_settings.activePetId);
      if (!wantOpen) {
        await _closeWindow();
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
        // Already showing the right pet. Nothing to do.
        return;
      }
      // Pet changed (or first launch). Tear down the old window
      // and spawn a fresh one.
      await _closeWindow();
      await _spawn(petId);
    } finally {
      _syncing = false;
    }
  }

  String? _resolvePetId(String? raw) {
    if (raw != null && raw.isNotEmpty) return raw;
    // Fall back to the bundled Anya when the user hasn't picked
    // anything yet. We hard-code the id here instead of touching
    // PetService (which would be an awkward layer swap inside
    // the controller). The id is stable across the app's lifetime.
    return 'builtin:anya';
  }

  Future<void> _spawn(String petId) async {
    try {
      final controller = await spawnPetWindow(petId: petId);
      _controller = controller;
      _controllerPetId = petId;
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
    if (controller == null) return;
    try {
      await closePetWindow(controller);
    } catch (_) {
      // The controller may already be closed (e.g. user X-ed the
      // window); ignore.
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