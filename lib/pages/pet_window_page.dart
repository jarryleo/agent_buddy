import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../models/pet.dart';
import '../services/pet_animation_controller.dart';
import '../services/pet_service.dart';
import '../services/pet_window_state_store.dart';
import '../widgets/pet_speech_bubble.dart';
import '../widgets/spritesheet_animation.dart';

/// Sentinel passed as `--type=pet` in the spawn arguments so the
/// main window (no `--type`) and the pet window can route
/// themselves into different `runApp(...)` branches.
const String _kPetWindowType = 'pet';

/// Argument key for the pet id.
const String _kPetIdArg = 'pet_id';

const String _kCloseMethod = 'close';
const String _kPlayOneShotMethod = 'playOneShot';
const String _kPlayLoopingMethod = 'playLooping';
const String _kResetMethod = 'reset';
const String _kSwitchPetMethod = 'switchPet';
const String _kShowTextMethod = 'showText';
const String _kShowMainMethod = 'showMain';
const String _kMoveToMethod = 'moveTo';
const String _kCancelMoveMethod = 'cancelMove';
const double _kBubbleAreaHeight = 80;
const double _kBubbleMinWidth = 100;
const Duration _kBubbleAutoHide = Duration(seconds: 10);

final PetWindowStateStore _windowStateStore = PetWindowStateStore();

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
  final position = await _resolveWindowPosition(size);
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
      await windowManager.setPosition(position);
      await windowManager.show(inactive: true);
    },
  );
}

Size _resolveWindowSize(Pet pet) {
  // Must match `_resolveWindowSizeWithBubble(false)` so the boot
  // surface has the same slack as the post-bubble surface — the
  // native window otherwise clips ~20px off the sprite at launch
  // (the same `setSize` rebuild that the bubble path triggers is
  // what makes the sprite appear "normal" once a bubble shows up).
  // The bubble slot itself is added on demand by
  // `_applyWindowSizeForBubble`, so an idle pet still has no empty
  // dead space above the sprite that would block mouse events on
  // whatever app sits behind it.
  return _resolveWindowSizeWithBubble(pet, withBubble: false);
}

Size _resolveWindowSizeWithBubble(Pet pet, {required bool withBubble}) {
  final sprite = petDisplaySize(pet);
  final width = sprite.width < _kBubbleMinWidth
      ? _kBubbleMinWidth
      : sprite.width;
  final height = withBubble
      ? sprite.height + _kBubbleAreaHeight
      : sprite.height;
  return Size(width, height + 20);
}

Future<Offset> _resolveWindowPosition(Size windowSize) async {
  final displays = await screenRetriever.getAllDisplays();
  final primary = await screenRetriever.getPrimaryDisplay();
  final saved = await _windowStateStore.loadPosition();
  var display = primary;
  if (saved != null) {
    for (final candidate in displays) {
      final origin = candidate.visiblePosition ?? Offset.zero;
      final size = candidate.visibleSize ?? candidate.size;
      if ((origin & size).contains(saved)) {
        display = candidate;
        break;
      }
    }
  }
  final origin = display.visiblePosition ?? Offset.zero;
  final workSize = display.visibleSize ?? display.size;
  final maxX = origin.dx + workSize.width - windowSize.width;
  final maxY = origin.dy + workSize.height - windowSize.height;
  final right = maxX < origin.dx ? origin.dx : maxX;
  final bottom = maxY < origin.dy ? origin.dy : maxY;
  if (saved == null) {
    return Offset(
      (right - 16).clamp(origin.dx, right),
      (bottom - 16).clamp(origin.dy, bottom),
    );
  }
  return Offset(
    saved.dx.clamp(origin.dx, right),
    saved.dy.clamp(origin.dy, bottom),
  );
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
      out[body.substring(0, eq)] = _decodeArgValue(body.substring(eq + 1));
    }
  }
  return out;
}

String _decodeArgValue(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return value;
  try {
    final decoded = Uri.decodeComponent(value);
    if (decoded != value || !decoded.startsWith('"')) return decoded;
  } catch (_) {}
  if (value.startsWith('"') && value.endsWith('"')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is String) return decoded;
    } catch (_) {}
  }
  return value;
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _PetWindow(pet: pet, controller: controller),
    );
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
  bool _petFrozen = false;
  String _speechText = '';
  bool _speechVisible = false;
  Timer? _speechHideTimer;
  int _pointerButton = 0;
  bool _dragging = false;
  String? _forcedDragAnimation;
  // True once the pointer has moved far enough that we consider
  // this a drag rather than a click. Below the threshold, a
  // pointer up is treated as a left-click (focuses the main app).
  bool _dragExceededClickThreshold = false;
  bool _hovering = false;
  Timer? _positionSaveTimer;
  OverlayEntry? _contextMenuEntry;
  Offset? _dragWindowPosition;
  Offset? _dragCursorPosition;
  Offset? _lastCursorPosition;
  Offset? _pendingWindowPosition;
  Timer? _dragPollTimer;
  bool _pollingDragPosition = false;
  bool _applyingWindowPosition = false;
  // Tracks the bubble visibility at the time of the last window
  // resize so the IPC handler only triggers a resize when the
  // desired state actually flips — redundant resizes are wasteful
  // and flicker on some platforms.
  bool _previousSpeechVisible = false;
  // `setSize` / `setPosition` both fire `onWindowMove` events,
  // which would otherwise pollute the saved position with the
  // bottom-anchored layout during bubble resize. Suppress the
  // save while the programmatic resize is in flight.
  bool _suppressPositionSave = false;
  // AI-driven movement: the pet director issues a `moveTo` over
  // IPC and we tween the window position over `_moveToDuration`,
  // flipping `run_left` / `run_right` based on the per-frame
  // delta. `_cancelMove()` is the pause path used by the
  // director when the main window goes busy.
  Timer? _moveToTimer;
  Offset? _moveToTarget;
  double _moveToPixelsPerFrame = 0;
  bool _moveToActive = false;
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
    widget.controller.setWindowMethodHandler((call) async {
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
        case _kSwitchPetMethod:
          final id = (call.arguments as Map?)?['id'] as String?;
          if (id != null && id.isNotEmpty) {
            await _switchPet(id);
          }
        case _kShowTextMethod:
          final text = (call.arguments as Map?)?['text'] as String?;
          if (text != null && mounted) {
            final wantBubble = text.trim().isNotEmpty;
            if (wantBubble && !_speechVisible) {
              await _applyWindowSizeForBubble(withBubble: true);
              if (!mounted) return null;
              _previousSpeechVisible = true;
              setState(() {
                _speechText = text;
                _speechVisible = true;
              });
            } else {
              setState(() {
                _speechText = text;
                _speechVisible = wantBubble;
              });
              _maybeResizeForBubble();
            }
            _scheduleSpeechHide();
          }
        case _kShowMainMethod:
          // No-op inside the pet window itself; the main engine
          // is the one that listens for this on its own channel
          // handler. We expose it symmetrically so the test
          // harness can poke either side.
          break;
        case _kMoveToMethod:
          final args = (call.arguments as Map?);
          final x = (args?['x'] as num?)?.toDouble();
          final y = (args?['y'] as num?)?.toDouble();
          final speed = (args?['speed'] as num?)?.toDouble();
          if (x != null && y != null && speed != null) {
            await _startMoveTo(x: x, y: y, speed: speed);
          }
        case _kCancelMoveMethod:
          await _cancelMoveTo();
      }
      return null;
    });

    windowManager.addListener(this);
  }

  @override
  void dispose() {
    unawaited(widget.controller.setWindowMethodHandler(null));
    _removeContextMenu();
    _speechHideTimer?.cancel();
    _positionSaveTimer?.cancel();
    _dragPollTimer?.cancel();
    _moveToTimer?.cancel();
    windowManager.removeListener(this);
    _anim.dispose();
    super.dispose();
  }

  @override
  void onWindowMove() {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_savePosition()),
    );
  }

  @override
  void onWindowMoved() {
    _positionSaveTimer?.cancel();
    unawaited(_savePosition());
  }

  Future<void> _switchPet(String id) async {
    final pet = await _resolvePet(id);
    if (pet == null || pet.id == _anim.pet.id) return;
    _anim.setPet(pet);
    // Greet the user with a wave before settling into the new
    // pet's default animation. Mirrors the boot animation so the
    // visual feedback stays consistent across cold start and a
    // mid-session pet swap. `playOneShot` is a silent no-op when
    // the new pet doesn't ship a `waving` strip.
    _anim.playOneShot('waving');
    // Re-derive the window size from the current bubble visibility
    // so a mid-session swap preserves the bubble slot if one is
    // already on screen.
    await _applyWindowSizeForBubble();
    await _savePosition();
  }

  Future<void> _savePosition() async {
    if (_suppressPositionSave) return;
    final position = await windowManager.getPosition();
    await _windowStateStore.savePosition(position);
  }

  /// Resize the OS window to match the current bubble visibility,
  /// keeping the sprite anchored to the same screen Y. Called
  /// whenever `_speechVisible` flips (and from `_switchPet` so a
  /// pet swap doesn't accidentally drop or restore the bubble
  /// slot).
  ///
  /// When the bubble is hidden the window is shrunk to just the
  /// sprite height, eliminating the empty ~80px strip at the top
  /// that would otherwise block mouse events on the app behind
  /// the pet. When the bubble is shown the window grows upward
  /// by `_kBubbleAreaHeight` and the bottom is held steady so the
  /// pet doesn't jump.
  Future<void> _applyWindowSizeForBubble({bool? withBubble}) async {
    final pet = _anim.pet;
    final newSize = _resolveWindowSizeWithBubble(
      pet,
      withBubble: withBubble ?? _speechVisible,
    );

    final currentPosition = await windowManager.getPosition();
    final currentSize = await windowManager.getSize();

    final targetBounds = Rect.fromLTWH(
      currentPosition.dx,
      currentPosition.dy + currentSize.height - newSize.height,
      newSize.width,
      newSize.height,
    );

    _suppressPositionSave = true;
    try {
      if (newSize.width > currentSize.width ||
          newSize.height > currentSize.height) {
        await windowManager.setMaximumSize(newSize);
        await windowManager.setBounds(targetBounds);
        await windowManager.setMinimumSize(newSize);
      } else {
        await windowManager.setMinimumSize(newSize);
        await windowManager.setBounds(targetBounds);
        await windowManager.setMaximumSize(newSize);
      }
    } catch (_) {
      // The window manager plugin can race during fast IPC bursts
      // (e.g. tool-driven speech loops). The next flip will
      // re-apply the correct size.
    } finally {
      // Keep suppression active long enough for the post-resize
      // `onWindowMove` echoes to settle, otherwise the debounced
      // save would persist the bottom-anchored position as the
      // new "preferred" one.
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _suppressPositionSave = false;
      });
    }
  }

  void _applyInteractionAnimation() {
    final dragAnimation = _forcedDragAnimation;
    if (dragAnimation != null) {
      _anim.forceLooping(dragAnimation);
    } else if (_hovering) {
      _anim.forceLooping('jumping');
    } else {
      _anim.clearForce();
    }
  }

  Future<void> _startDrag(PointerDownEvent event) async {
    _pointerButton = event.buttons;
    if (event.buttons & kSecondaryButton != 0) {
      await _openContextMenu(event.position);
      return;
    }
    if (event.buttons & kPrimaryButton == 0) return;
    _dragging = true;
    _dragExceededClickThreshold = false;
    _forcedDragAnimation = null;
    _dragWindowPosition = await windowManager.getPosition();
    _dragCursorPosition = await screenRetriever.getCursorScreenPoint();
    _lastCursorPosition = _dragCursorPosition;
    _dragPollTimer?.cancel();
    _dragPollTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => unawaited(_pollDragPosition()),
    );
  }

  Future<void> _pollDragPosition() async {
    if (!_dragging || _pollingDragPosition) return;
    _pollingDragPosition = true;
    try {
      final cursor = await screenRetriever.getCursorScreenPoint();
      final cursorOrigin = _dragCursorPosition;
      final windowOrigin = _dragWindowPosition;
      final previous = _lastCursorPosition;
      if (cursorOrigin == null || windowOrigin == null || previous == null) {
        return;
      }
      _lastCursorPosition = cursor;
      final totalDx = cursor.dx - cursorOrigin.dx;
      final totalDy = cursor.dy - cursorOrigin.dy;
      if (totalDx.abs() + totalDy.abs() >= _kClickThreshold) {
        _dragExceededClickThreshold = true;
      }
      final frameDx = cursor.dx - previous.dx;
      if (frameDx.abs() >= 0.5) {
        final animation = frameDx < 0 ? 'run_left' : 'run_right';
        if (_forcedDragAnimation != animation) {
          _forcedDragAnimation = animation;
          _applyInteractionAnimation();
        }
      }
      _pendingWindowPosition = Offset(
        windowOrigin.dx + totalDx,
        windowOrigin.dy + totalDy,
      );
      unawaited(_applyPendingWindowPosition());
    } finally {
      _pollingDragPosition = false;
    }
  }

  Future<void> _applyPendingWindowPosition() async {
    if (_applyingWindowPosition) return;
    _applyingWindowPosition = true;
    try {
      while (_pendingWindowPosition != null) {
        final target = _pendingWindowPosition!;
        _pendingWindowPosition = null;
        await windowManager.setPosition(target);
      }
    } finally {
      _applyingWindowPosition = false;
    }
  }

  /// Starts an AI-driven tween from the pet's current window
  /// position to `(x, y)` at `speed` pixels per second. The pet
  /// plays `run_left` / `run_right` based on the per-frame delta
  /// (same convention as the drag handler) and falls back to
  /// `idle` on completion. Ignored when the user is dragging
  /// (drag takes priority over the AI's plan). The director can
  /// cancel mid-flight via [_kCancelMoveMethod]; the pet stops
  /// where it is and reverts to its default animation.
  Future<void> _startMoveTo({
    required double x,
    required double y,
    required double speed,
  }) async {
    if (_dragging) return;
    if (_petFrozen) {
      // Play the run animation in the direction of the target without
      // actually moving the window.
      final current = await windowManager.getPosition();
      final dir = (x - current.dx) < 0 ? 'run_left' : 'run_right';
      _anim.forceLooping(dir);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted || _dragging) return;
        _forcedDragAnimation = null;
        _anim.clearForce();
      });
      return;
    }
    final cleanSpeed = speed.clamp(8.0, 480.0);
    _moveToTimer?.cancel();
    _moveToTarget = Offset(x, y);
    _moveToPixelsPerFrame = cleanSpeed * 0.033;
    _moveToActive = true;
    _moveToTimer = Timer.periodic(
      const Duration(milliseconds: 33),
      (_) => unawaited(_stepMoveTo()),
    );
    await _stepMoveTo();
  }

  Future<void> _stepMoveTo() async {
    if (!_moveToActive || _moveToTarget == null) return;
    if (_dragging) {
      await _cancelMoveTo();
      return;
    }
    Offset current;
    try {
      current = await windowManager.getPosition();
    } catch (_) {
      await _cancelMoveTo();
      return;
    }
    final size = _currentWindowSize();
    final clamped = await _clampTargetToVisibleArea(_moveToTarget!, size);
    final delta = clamped - current;
    final distance = delta.distance;
    if (distance <= _moveToPixelsPerFrame) {
      _suppressPositionSave = true;
      try {
        await windowManager.setPosition(clamped);
      } catch (_) {
        // The window-manager plugin can race during a fast
        // IPC burst (e.g. the director chaining moves); the
        // next step will pull the live position again.
      } finally {
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) _suppressPositionSave = false;
        });
      }
      await _finishMoveTo();
      return;
    }
    final step = delta / distance * _moveToPixelsPerFrame;
    final next = current + step;
    final direction = step.dx < 0 ? 'run_left' : 'run_right';
    if (_forcedDragAnimation != direction) {
      _forcedDragAnimation = direction;
      _anim.forceLooping(direction);
    }
    try {
      await windowManager.setPosition(next);
    } catch (_) {
      // Skip this frame; the next tick will retry against the
      // live position.
    }
  }

  Future<void> _finishMoveTo() async {
    _moveToTimer?.cancel();
    _moveToTimer = null;
    _moveToActive = false;
    _moveToTarget = null;
    _moveToPixelsPerFrame = 0;
    // Only clear the run animation if the user isn't currently
    // dragging. Drag ownership is enforced in `_endDrag` already.
    if (!_dragging) {
      _forcedDragAnimation = null;
      _anim.clearForce();
    }
    await _savePosition();
  }

  Future<void> _cancelMoveTo() async {
    _moveToTimer?.cancel();
    _moveToTimer = null;
    if (!_moveToActive) return;
    _moveToActive = false;
    _moveToTarget = null;
    _moveToPixelsPerFrame = 0;
    if (!_dragging) {
      _forcedDragAnimation = null;
      _anim.clearForce();
    }
  }

  Size _currentWindowSize() {
    final pet = _anim.pet;
    final bubbleArea = _speechVisible ? _kBubbleAreaHeight : 0.0;
    final sprite = petDisplaySize(pet);
    final width = sprite.width < _kBubbleMinWidth
        ? _kBubbleMinWidth
        : sprite.width;
    return Size(width, sprite.height + bubbleArea + 20);
  }

  /// Clamp a target OS-level position so the pet's window stays
  /// fully inside the visible work area of the display that
  /// currently contains the pet. Prevents the AI from placing
  /// the pet on cursor-invisible coordinates or off-screen.
  Future<Offset> _clampTargetToVisibleArea(Offset target, Size size) async {
    final displays = await screenRetriever.getAllDisplays();
    final primary = await screenRetriever.getPrimaryDisplay();
    final current = await windowManager.getPosition();
    var display = primary;
    for (final candidate in displays) {
      final origin = candidate.visiblePosition ?? Offset.zero;
      final work = candidate.visibleSize ?? candidate.size;
      final rect = origin & work;
      if (rect.contains(current)) {
        display = candidate;
        break;
      }
    }
    final origin = display.visiblePosition ?? Offset.zero;
    final work = display.visibleSize ?? display.size;
    final maxX = origin.dx + work.width - size.width;
    final maxY = origin.dy + work.height - size.height;
    return Offset(
      target.dx.clamp(origin.dx, maxX < origin.dx ? origin.dx : maxX),
      target.dy.clamp(origin.dy, maxY < origin.dy ? origin.dy : maxY),
    );
  }

  Future<void> _endDrag(PointerUpEvent event) async {
    if (!_dragging) return;
    _dragging = false;
    _dragPollTimer?.cancel();
    _dragPollTimer = null;
    await _applyPendingWindowPosition();
    while (_applyingWindowPosition) {
      await Future<void>.delayed(Duration.zero);
    }
    final wasClick = !_dragExceededClickThreshold;
    _dragWindowPosition = null;
    _dragCursorPosition = null;
    _lastCursorPosition = null;
    _forcedDragAnimation = null;
    _applyInteractionAnimation();
    if (!wasClick) {
      await _savePosition();
    }
    if (wasClick && event.kind == PointerDeviceKind.mouse) {
      if (_pointerButton & kPrimaryButton != 0) {
        await _requestShowMain();
      }
    }
    _pointerButton = 0;
  }

  Future<void> _requestShowMain() async {
    try {
      await widget.controller.invokeMethod<bool>(_kShowMainMethod);
    } catch (_) {}
  }

  void _removeContextMenu() {
    _contextMenuEntry?.remove();
    _contextMenuEntry = null;
  }

  void _scheduleSpeechHide() {
    _speechHideTimer?.cancel();
    if (_speechText.trim().isEmpty) {
      // Empty text means the bubble was already hidden by the IPC
      // handler's `setState`; nothing to schedule.
      return;
    }
    _speechHideTimer = Timer(_kBubbleAutoHide, () {
      if (!mounted) return;
      setState(() => _speechVisible = false);
      _maybeResizeForBubble();
    });
  }

  /// Triggers a window resize when the bubble visibility flips. Used
  /// by both the IPC handler (text-driven show / hide) and the
  /// auto-hide timer (10-second fade) so the OS window shrinks back
  /// down no matter *which* code path hid the bubble.
  void _maybeResizeForBubble() {
    if (_previousSpeechVisible == _speechVisible) return;
    _previousSpeechVisible = _speechVisible;
    unawaited(_applyWindowSizeForBubble());
  }

  Future<void> _openContextMenu(Offset position) async {
    _removeContextMenu();
    final overlay = Overlay.of(context, rootOverlay: true);
    final size = MediaQuery.sizeOf(context);
    final left = position.dx.clamp(
      0.0,
      (size.width - 96).clamp(0.0, size.width),
    );
    final top = position.dy.clamp(
      0.0,
      (size.height - 110).clamp(0.0, size.height),
    );
    final entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => _removeContextMenu(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
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
                        _removeContextMenu();
                        _toggleClickThrough();
                      },
                    ),
                    _MenuItem(
                      label: _petFrozen ? '自由活动' : '乖乖别动',
                      onTap: () {
                        _removeContextMenu();
                        _togglePetFrozen();
                      },
                    ),
                    _MenuItem(
                      label: '关闭桌宠',
                      color: Colors.redAccent,
                      onTap: () {
                        _removeContextMenu();
                        _hideWindow();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _contextMenuEntry = entry;
    overlay.insert(entry);
  }

  Future<void> _toggleClickThrough() async {
    final next = !_clickThrough;
    setState(() => _clickThrough = next);
    await windowManager.setIgnoreMouseEvents(next);
  }

  void _togglePetFrozen() {
    setState(() => _petFrozen = !_petFrozen);
    if (_petFrozen && _moveToActive) {
      unawaited(_cancelMoveTo());
    }
  }

  Future<void> _hideWindow() async {
    // Closing via `windowManager.close()` tears down the engine so
    // the next toggle-on has to respawn. We use close() so the
    // lifecycle stays symmetrical with the toggle-off path.
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0x00000000),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _startDrag,
              onPointerUp: _endDrag,
              onPointerCancel: (event) {
                _dragging = false;
                _pointerButton = 0;
                _dragWindowPosition = null;
                _dragCursorPosition = null;
                _lastCursorPosition = null;
                _pendingWindowPosition = null;
                _dragPollTimer?.cancel();
                _dragPollTimer = null;
                _forcedDragAnimation = null;
                _applyInteractionAnimation();
              },
              child: MouseRegion(
                onEnter: (_) {
                  _hovering = true;
                  _applyInteractionAnimation();
                },
                onExit: (_) {
                  _hovering = false;
                  _applyInteractionAnimation();
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: petDisplaySize(widget.pet).height,
                      child: Center(
                        child: SpritesheetAnimation(controller: _anim),
                      ),
                    ),
                    Positioned(
                      left: 6,
                      right: 6,
                      top: 6,
                      height: _kBubbleAreaHeight,
                      child: IgnorePointer(
                        child: _speechVisible
                            ? PetSpeechBubble(text: _speechText)
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_clickThrough)
            const Positioned(right: 2, top: 2, child: _ClickThroughBadge()),
        ],
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
  final encodedPetId = Uri.encodeComponent(petId);
  final args = '--type=$_kPetWindowType --$_kPetIdArg=$encodedPetId';
  final controller = await WindowController.create(
    WindowConfiguration(hiddenAtLaunch: true, arguments: args),
  );
  return controller;
}

/// Asks the pet window to close itself. Returns when the message
/// is dispatched (does not wait for the window to actually go
/// away — the `onWindowsChanged` stream surfaces that).
Future<void> closePetWindow(WindowController controller) async {
  try {
    await controller.invokeMethod<bool>(_kCloseMethod);
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
  try {
    await controller.invokeMethod<bool>(_kPlayOneShotMethod, {'name': name});
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
  try {
    await controller.invokeMethod<bool>(_kPlayLoopingMethod, {'name': name});
  } catch (_) {}
}

Future<void> sendPetShowText(WindowController controller, String text) async {
  try {
    await controller.invokeMethod<bool>(_kShowTextMethod, {'text': text});
  } catch (_) {}
}

Future<bool> sendPetSwitch(WindowController controller, String id) async {
  try {
    await controller.invokeMethod<bool>(_kSwitchPetMethod, {'id': id});
    return true;
  } catch (_) {
    return false;
  }
}

/// Resets the pet to its default animation (typically `idle`).
Future<void> sendPetReset(WindowController controller) async {
  try {
    await controller.invokeMethod<bool>(_kResetMethod);
  } catch (_) {}
}

/// Asks the pet window to start an AI-driven tween from its
/// current position to `(x, y)` at `speed` pixels per second.
/// The pet swaps to `run_left` / `run_right` based on the
/// per-frame delta and falls back to `idle` once it reaches the
/// target. The director can interrupt mid-flight via
/// [sendPetCancelMove].
Future<void> sendPetMoveTo(
  WindowController controller, {
  required double x,
  required double y,
  required double speed,
}) async {
  try {
    await controller.invokeMethod<bool>(_kMoveToMethod, {
      'x': x,
      'y': y,
      'speed': speed,
    });
  } catch (_) {
    // The pet window may have been closed between the
    // initial check and the move IPC; ignore.
  }
}

/// Interrupts an in-flight AI-driven move. The pet stops where
/// it is and drops back to its default animation. Safe to call
/// when no move is in flight (the pet window no-ops).
Future<void> sendPetCancelMove(WindowController controller) async {
  try {
    await controller.invokeMethod<bool>(_kCancelMoveMethod);
  } catch (_) {}
}

/// Sentinel exposed for the main window's `runApp` branch — when
/// `bootstrap()` sees `--type=pet` in its args it dispatches into
/// the pet window. Used by `main.dart`.
const String petWindowType = _kPetWindowType;
