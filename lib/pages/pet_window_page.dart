import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models/pet.dart';
import '../services/pet_animation_controller.dart';
import '../services/pet_service.dart';
import '../widgets/spritesheet_animation.dart';

/// Sentinel passed as `--type=pet` in the spawn arguments so the
/// main window (no `--type`) and the pet window can route
/// themselves into different `runApp(...)` branches.
const String _kPetWindowType = 'pet';

/// Argument key for the pet id.
const String _kPetIdArg = 'pet_id';

/// Cross-window channel for the pet window. The main engine sends
/// `close` here when the user flips the toggle off; the pet window
/// receives it and runs `windowManager.close()`.
const String _kPetChannel = 'agent_buddy/pet_window';

const String _kCloseMethod = 'close';
const String _kPlayOneShotMethod = 'playOneShot';
const String _kPlayLoopingMethod = 'playLooping';
const String _kResetMethod = 'reset';
const String _kShowMainMethod = 'showMain';

/// Entry-point invoked by `desktop_multi_window` when a sub-window
/// is spawned. The CLI passes `--type=pet --pet_id=<id>` and we
/// return the `runApp` target. We do this in [bootstrapPetWindow]
/// below so the existing `main.dart` only has to call one helper.
Future<void> runPetWindow(WindowController controller) async {
  WidgetsFlutterBinding.ensureInitialized();

  final args = _parseArgs(controller.arguments);
  final petId = args[_kPetIdArg] ?? '';
  final pet = await _resolvePet(petId);

  if (pet != null) {
    await _configurePetWindow(pet);
  }

  runApp(_PetWindowApp(pet: pet, controller: controller));
}

/// Re-implementation of `getApplicationDocumentsDirectory` for the
/// sub-engine. `path_provider` only wires up the main engine's
/// documents dir; the sub-engine's call would return the default
/// `path_provider` channel binding, which is the same underlying
/// directory on every platform but it's worth confirming rather
/// than trusting.
Future<Pet?> _resolvePet(String petId) async {
  final svc = PetService();
  final pets = await svc.ensureReady();
  if (petId.isEmpty) {
    return pets.isNotEmpty ? pets.first : null;
  }
  for (final p in pets) {
    if (p.id == petId) return p;
  }
  return null;
}

Future<void> _configurePetWindow(Pet pet) async {
  // Transparent background + frameless + always-on-top: the pet
  // should feel like a floating sprite, not another OS window.
  // The OS-level window is exactly one sprite frame wide/tall so
  // there's no extra chrome to click on.
  final size = _resolveWindowSize(pet);
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: size,
      center: false,
      backgroundColor: const Color(0x00000000),
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      alwaysOnTop: true,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setHasShadow(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setMaximizable(false);
      await windowManager.setResizable(false);
      await windowManager.setMinimumSize(size);
      await windowManager.setMaximumSize(size);
      await windowManager.show();
      await windowManager.focus();
    },
  );
}

Size _resolveWindowSize(Pet pet) {
  final scale = pet.scale <= 0 ? 1.0 : pet.scale;
  final w = (pet.frameWidth * scale).clamp(48.0, 1024.0);
  final h = (pet.frameHeight * scale).clamp(48.0, 1024.0);
  return Size(w, h);
}

Map<String, String> _parseArgs(String? args) {
  if (args == null || args.isEmpty) return const {};
  // The plugin forwards arguments as a single space-separated
  // string of `--key=value` pairs.
  final out = <String, String>{};
  for (final token in args.split(RegExp(r'\s+'))) {
    if (!token.startsWith('--')) continue;
    final body = token.substring(2);
    final eq = body.indexOf('=');
    if (eq < 0) {
      out[body] = '';
    } else {
      out[body.substring(0, eq)] = body.substring(eq + 1);
    }
  }
  return out;
}

class _PetWindowApp extends StatelessWidget {
  const _PetWindowApp({required this.pet, required this.controller});

  final Pet? pet;
  final WindowController controller;

  @override
  Widget build(BuildContext context) {
    final pet = this.pet;
    if (pet == null) {
      // Pet was deleted before the window finished loading. Just
      // shut down — the main window's listener will relaunch when
      // the user picks another.
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const _PetMissingPage(),
      );
    }
    // The pet window owns its own PetService instance — the main
    // app's instance is in a different isolate and we can't share.
    // The two instances are kept in sync via the on-disk
    // manifest, which the provider reads on demand.
    return _PetWindow(pet: pet, controller: controller);
  }
}

class _PetWindow extends StatefulWidget {
  const _PetWindow({required this.pet, required this.controller});
  final Pet pet;
  final WindowController controller;

  @override
  State<_PetWindow> createState() => _PetWindowState();
}

class _PetWindowState extends State<_PetWindow> with WindowListener {
  late final PetAnimationController _anim;
  bool _clickThrough = false;
  bool _dragging = false;
  double _dragDx = 0;
  double _dragDy = 0;
  // The animation we forced while dragging. `null` means the pet
  // is in its natural state (driving itself). Cleared on pointer up.
  String? _forcedDragAnimation;
  // True once the pointer has moved far enough that we consider
  // this a drag rather than a click. Below the threshold, a
  // pointer up is treated as a left-click (focuses the main app).
  bool _dragExceededClickThreshold = false;
  static const double _kClickThreshold = 6;

  @override
  void initState() {
    super.initState();
    _anim = PetAnimationController(pet: widget.pet);
    // Boot animation: play `waving` once, then drop into the
    // pet's default (typically `idle`). We schedule the one-shot
    // after the first frame so the listener can wire up before
    // the renderer kicks off.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anim.playOneShot('waving');
    });

    // Register the IPC channel that lets the main window drive
    // the pet's animation state machine. Bidirectional because
    // we also send `showMain` back when the user left-clicks the
    // pet.
    const channel = WindowMethodChannel(
      _kPetChannel,
      mode: ChannelMode.bidirectional,
    );
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case _kCloseMethod:
          await windowManager.close();
        case _kPlayOneShotMethod:
          final name = (call.arguments as Map?)?['name'] as String?;
          if (name != null && name.isNotEmpty) {
            _anim.playOneShot(name);
          }
        case _kPlayLoopingMethod:
          final name = (call.arguments as Map?)?['name'] as String?;
          if (name != null && name.isNotEmpty) {
            _anim.playLooping(name);
          }
        case _kResetMethod:
          _anim.reset();
        case _kShowMainMethod:
          // No-op inside the pet window itself; the main engine
          // is the one that listens for this on its own channel
          // handler. We expose it symmetrically so the test
          // harness can poke either side.
          break;
      }
      return null;
    });

    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _anim.dispose();
    super.dispose();
  }

  Future<void> _startDrag(PointerDownEvent event) async {
    _dragging = true;
    _dragDx = 0;
    _dragDy = 0;
    _dragExceededClickThreshold = false;
    _forcedDragAnimation = null;
  }

  Future<void> _onDrag(PointerMoveEvent event) async {
    if (!_dragging) return;
    if (_clickThrough) return;
    _dragDx += event.delta.dx;
    _dragDy += event.delta.dy;
    final totalDelta = _dragDx.abs() + _dragDy.abs();
    if (!_dragExceededClickThreshold && totalDelta >= _kClickThreshold) {
      _dragExceededClickThreshold = true;
    }
    if (_dragExceededClickThreshold) {
      // Pick the dominant axis. We only swap to a run animation
      // when the dominant axis wins by a 1.4× margin so a slightly
      // diagonal drag doesn't flicker between run_left / run_right.
      final animName = _dragDx.abs() >= _dragDy.abs() * 1.4
          ? (_dragDx >= 0 ? 'run_right' : 'run_left')
          : null;
      if (animName != _forcedDragAnimation) {
        _forcedDragAnimation = animName;
        if (animName != null) {
          _anim.playLooping(animName);
        }
      }
      final pos = await windowManager.getPosition();
      await windowManager.setPosition(
        Offset(pos.dx + event.delta.dx, pos.dy + event.delta.dy),
      );
    }
  }

  Future<void> _endDrag(PointerUpEvent event) async {
    if (!_dragging) return;
    _dragging = false;
    final wasClick = !_dragExceededClickThreshold;
    final hadForcedAnim = _forcedDragAnimation != null;
    _forcedDragAnimation = null;
    if (hadForcedAnim) {
      // Drop back to whatever the chat provider last picked.
      // `reset()` returns to the pet's default (idle); for the
      // thinking / streaming overrides the chat provider will
      // re-assert its looping animation as soon as it sees the
      // next event.
      _anim.reset();
    }
    if (wasClick && event.kind == PointerDeviceKind.mouse) {
      if (event.buttons & kPrimaryButton != 0) {
        await _requestShowMain();
      } else if (event.buttons & kSecondaryButton != 0) {
        // Right-click without drag opens the menu.
        await _openContextMenu(event.position);
      }
    }
  }

  Future<void> _requestShowMain() async {
    const channel = WindowMethodChannel(
      _kPetChannel,
      mode: ChannelMode.bidirectional,
    );
    try {
      await channel.invokeMethod<bool>(_kShowMainMethod);
    } catch (_) {
      // The main window may not have a handler registered yet.
      // The fallback is that the OS-level "show main" shortcut
      // (e.g. clicking the taskbar icon) still works.
    }
  }

  Future<void> _openContextMenu(Offset position) async {
    // We use a synthetic Overlay rather than a long-press-style
    // menu because the pet window is frameless and has no
    // Material chrome to anchor against. The popup is positioned
    // at the right-click point so muscle memory still works.
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        return Positioned(
          left: position.dx,
          top: position.dy,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MenuItem(
                    label: _clickThrough ? '取消穿透' : '鼠标穿透',
                    onTap: () {
                      entry.remove();
                      _toggleClickThrough();
                    },
                  ),
                  _MenuItem(
                    label: '关闭桌宠',
                    color: Colors.redAccent,
                    onTap: () {
                      entry.remove();
                      _hideWindow();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
  }

  Future<void> _toggleClickThrough() async {
    final next = !_clickThrough;
    setState(() => _clickThrough = next);
    await windowManager.setIgnoreMouseEvents(next);
  }

  Future<void> _hideWindow() async {
    // Closing via `windowManager.close()` tears down the engine so
    // the next toggle-on has to respawn. We use close() so the
    // lifecycle stays symmetrical with the toggle-off path.
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // Transparent scaffold so the OS-level window background
      // (also transparent) shows through everywhere except the
      // sprite itself.
      home: Scaffold(
        backgroundColor: const Color(0x00000000),
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _startDrag,
                onPointerMove: _onDrag,
                onPointerUp: _endDrag,
                onPointerCancel: (event) {
                  _dragging = false;
                  _forcedDragAnimation = null;
                  _anim.reset();
                },
                child: Center(child: SpritesheetAnimation(controller: _anim)),
              ),
            ),
            // Small click-through badge so the user always knows
            // whether pointer events pass through. Hidden when
            // normal so it doesn't steal focus.
            if (_clickThrough)
              const Positioned(right: 2, top: 2, child: _ClickThroughBadge()),
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({required this.label, required this.onTap, this.color});
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            color: color ?? Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _ClickThroughBadge extends StatelessWidget {
  const _ClickThroughBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.visibility_off_outlined,
        size: 10,
        color: Colors.white,
      ),
    );
  }
}

class _PetMissingPage extends StatefulWidget {
  const _PetMissingPage();

  @override
  State<_PetMissingPage> createState() => _PetMissingPageState();
}

class _PetMissingPageState extends State<_PetMissingPage> {
  @override
  void initState() {
    super.initState();
    // Auto-close after the first frame so a missing pet doesn't
    // leave a transparent ghost window open.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.close();
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0x00000000),
      body: SizedBox.shrink(),
    );
  }
}

/// Helper used by `main.dart` to spawn the pet window. Kept here so
/// the multi-window bootstrap and the main-window lifecycle code
/// share a single definition of the spawn arguments.
Future<WindowController> spawnPetWindow({required String petId}) async {
  final args = '$_kPetWindowType --$_kPetIdArg=${jsonEncode(petId)}';
  final controller = await WindowController.create(
    WindowConfiguration(hiddenAtLaunch: true, arguments: args),
  );
  return controller;
}

/// Asks the pet window to close itself. Returns when the message
/// is dispatched (does not wait for the window to actually go
/// away — the `onWindowsChanged` stream surfaces that).
Future<void> closePetWindow(WindowController controller) async {
  const channel = WindowMethodChannel(
    _kPetChannel,
    mode: ChannelMode.bidirectional,
  );
  try {
    await channel.invokeMethod<bool>(_kCloseMethod);
  } catch (_) {
    // The window may already be gone. The lifecycle owner will
    // notice via `onWindowsChanged` and clean up.
  }
}

/// Forwards a one-shot animation request to the pet window. The
/// chat provider calls this on tool success / failure / startup.
Future<void> sendPetPlayOneShot(
  WindowController controller,
  String name,
) async {
  const channel = WindowMethodChannel(
    _kPetChannel,
    mode: ChannelMode.bidirectional,
  );
  try {
    await channel.invokeMethod<bool>(_kPlayOneShotMethod, {'name': name});
  } catch (_) {
    // The pet window may have been closed between the
    // `showDesktopPet` flip and the tool finishing — ignore.
  }
}

/// Forwards a looping animation request. The chat provider calls
/// this when the model starts thinking / streaming / running a tool.
Future<void> sendPetPlayLooping(
  WindowController controller,
  String name,
) async {
  const channel = WindowMethodChannel(
    _kPetChannel,
    mode: ChannelMode.bidirectional,
  );
  try {
    await channel.invokeMethod<bool>(_kPlayLoopingMethod, {'name': name});
  } catch (_) {}
}

/// Resets the pet to its default animation (typically `idle`).
Future<void> sendPetReset(WindowController controller) async {
  const channel = WindowMethodChannel(
    _kPetChannel,
    mode: ChannelMode.bidirectional,
  );
  try {
    await channel.invokeMethod<bool>(_kResetMethod);
  } catch (_) {}
}

/// Sentinel exposed for the main window's `runApp` branch — when
/// `bootstrap()` sees `--type=pet` in its args it dispatches into
/// the pet window. Used by `main.dart`.
const String petWindowType = _kPetWindowType;
