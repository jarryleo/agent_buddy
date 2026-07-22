import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../models/pet.dart';
import '../services/pet_animation_controller.dart';

Size petDisplaySize(Pet pet) {
  if (pet.frameWidth <= 0 || pet.frameHeight <= 0) return const Size(0, 0);
  var width = pet.frameWidth.toDouble();
  var height = pet.frameHeight.toDouble();
  final largest = width > height ? width : height;
  if (largest > 160) {
    final reduction = 160 / largest;
    width *= reduction;
    height *= reduction;
  }
  return Size(width, height);
}

/// Renders the currently-active animation strip from a pet's
/// spritesheet. Steps through the strip at the pet's `fps`. For
/// looping animations the controller `repeat()`s forever; for
/// one-shots it `forward()`s once and notifies
/// [PetAnimationController.notifyOneShotCompleted] so the state
/// machine drops back to the default animation.
///
/// Sized to one frame at the pet's `scale` so the surrounding
/// window can be sized to match.
class SpritesheetAnimation extends StatefulWidget {
  const SpritesheetAnimation({super.key, required this.controller});

  final PetAnimationController controller;

  @override
  State<SpritesheetAnimation> createState() => _SpritesheetAnimationState();
}

class _SpritesheetAnimationState extends State<SpritesheetAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  ImageProvider? _provider;
  ui.Image? _decoded;
  bool _failed = false;
  ImageStreamListener? _listener;
  ImageStream? _stream;
  PetAnimation _animation = PetAnimation(
    name: '_placeholder',
    row: 0,
    frameCount: 1,
  );
  bool _oneShotActive = false;
  late int _revision;

  @override
  void initState() {
    super.initState();
    _animation = widget.controller.current;
    _revision = widget.controller.revision;
    _controller = AnimationController(vsync: this);
    _configureForCurrentAnimation();
    widget.controller.addListener(_onControllerChanged);
    _resolveProvider();
  }

  void _configureForCurrentAnimation() {
    final animation = _animation;
    final configuredFps = widget.controller.pet.fps;
    final fps = configuredFps <= 6.0 ? 5.0 : configuredFps;
    final durationMs = ((animation.frameCount / fps) * 1000).round();
    _controller.duration = Duration(
      milliseconds: durationMs <= 0 ? 1 : durationMs,
    );
    _controller.removeStatusListener(_onAnimationStatus);
    _controller.addStatusListener(_onAnimationStatus);
    if (animation.loop) {
      _oneShotActive = false;
      _controller.repeat();
    } else {
      _oneShotActive = true;
      _controller
        ..reset()
        ..forward();
    }
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    if (!_oneShotActive) return;
    _oneShotActive = false;
    widget.controller.notifyOneShotCompleted();
  }

  void _onControllerChanged() {
    final newAnim = widget.controller.current;
    final newRevision = widget.controller.revision;
    if (newRevision == _revision &&
        newAnim.name == _animation.name &&
        newAnim.row == _animation.row &&
        newAnim.frameCount == _animation.frameCount &&
        newAnim.loop == _animation.loop) {
      return;
    }
    _revision = newRevision;
    setState(() {
      _animation = newAnim;
      _configureForCurrentAnimation();
    });
    // Some pet switches may carry a different spritesheet (the
    // user picked a different pet). Re-resolve the image
    // provider; the listener below dedupes via the image cache.
    if (widget.controller.pet.id != _lastResolvedPetId) {
      _stream?.removeListener(_listener!);
      _decoded = null;
      _failed = false;
      _resolveProvider();
    }
  }

  String? _lastResolvedPetId;

  void _resolveProvider() {
    final pet = widget.controller.pet;
    _lastResolvedPetId = pet.id;
    ImageProvider? provider;
    final abs = pet.resolveAbsoluteSpritesheetPath();
    if (abs != null) {
      final f = File(abs);
      if (f.existsSync()) {
        provider = FileImage(f);
      }
    }
    if (provider == null && pet.assetSpritesheetPath != null) {
      provider = AssetImage(pet.assetSpritesheetPath!);
    }
    if (provider == null) {
      setState(() => _failed = true);
      return;
    }
    _provider = provider;
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _decoded = info.image);
      },
      onError: (_, _) {
        if (!mounted) return;
        setState(() => _failed = true);
      },
    );
    _stream = provider.resolve(ImageConfiguration.empty);
    _stream!.addListener(_listener!);
  }

  @override
  void didUpdateWidget(covariant SpritesheetAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      // The whole pet swapped (e.g. parent rebuilt). Reconfigure
      // from scratch.
      _stream?.removeListener(_listener!);
      _decoded = null;
      _failed = false;
      _animation = widget.controller.current;
      _configureForCurrentAnimation();
      _resolveProvider();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    if (_listener != null) {
      _stream?.removeListener(_listener!);
    }
    _controller.dispose();
    super.dispose();
  }

  int _currentFrame() {
    if (_animation.frameCount <= 0) return 0;
    final value = _controller.value.clamp(0.0, 1.0);
    return (value * _animation.frameCount).floor().clamp(
      0,
      _animation.frameCount - 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_failed || _provider == null) {
      return const SizedBox.shrink();
    }
    final pet = widget.controller.pet;
    final frameW = pet.frameWidth.toDouble();
    final frameH = pet.frameHeight.toDouble();
    final displaySize = petDisplaySize(pet);
    return SizedBox(
      width: displaySize.width,
      height: displaySize.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final frame = _currentFrame();
          return CustomPaint(
            painter: _SpritesheetPainter(
              image: _decoded,
              row: _animation.row,
              column: frame,
              frameWidth: frameW,
              frameHeight: frameH,
            ),
          );
        },
      ),
    );
  }
}

class _SpritesheetPainter extends CustomPainter {
  _SpritesheetPainter({
    required this.image,
    required this.row,
    required this.column,
    required this.frameWidth,
    required this.frameHeight,
  });

  final ui.Image? image;
  final int row;
  final int column;
  final double frameWidth;
  final double frameHeight;

  @override
  void paint(Canvas canvas, Size size) {
    if (frameWidth <= 0 || frameHeight <= 0) return;
    final decoded = image;
    if (decoded == null) return;
    final src = Rect.fromLTWH(
      column * frameWidth,
      row * frameHeight,
      frameWidth,
      frameHeight,
    );
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(decoded, src, dst, Paint());
  }

  @override
  bool shouldRepaint(covariant _SpritesheetPainter oldDelegate) {
    return oldDelegate.row != row ||
        oldDelegate.column != column ||
        oldDelegate.image != image;
  }
}
