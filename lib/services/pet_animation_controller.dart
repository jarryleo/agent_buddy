import 'package:flutter/foundation.dart';

import '../models/pet.dart';

/// High-level animation state machine. Owns the active animation
/// and arbitrates between competing requests:
///
///   * `playOneShot(name)` — play a non-looping animation once,
///     then return to the pet's default (typically `idle`).
///   * `playLooping(name)` — switch into a looping animation.
///     Stays until something else takes over.
///   * `reset()` — return to the default animation immediately.
///
/// A typical flow looks like:
///   1. App boot → pet window auto-plays `waving` once, then drops
///      into `idle`.
///   2. User sends a message → `playLooping('waiting')` (model is
///      thinking).
///   3. Model starts streaming → `playLooping('review')`.
///   4. Model stops streaming → `reset()` (back to `idle`).
///   5. Model calls a tool → `playLooping('running')`.
///   6. Tool returns success → `playOneShot('jumping')`.
///   7. Tool returns failure → `playOneShot('failed')`.
///
/// The controller is intentionally framework-free so the pet
/// window can construct one synchronously in `initState`. The
/// windowing layer (see [PetWindowController] /
/// [PetAnimationChannel]) is responsible for forwarding
/// `playOneShot` / `playLooping` / `reset` calls across the
/// multi-window boundary.
class PetAnimationController extends ChangeNotifier {
  PetAnimationController({required Pet pet})
    : _pet = pet,
      _current =
          pet.animationByName(pet.defaultAnimation) ??
          (pet.animations.isNotEmpty
              ? pet.animations.first
              : _missingAnimation);

  static final PetAnimation _missingAnimation = PetAnimation(
    name: 'missing',
    row: 0,
    frameCount: 1,
    loop: true,
  );

  Pet _pet;
  PetAnimation _current;
  PetAnimation? _override;
  int _oneShotRepeatsRemaining = 0;
  int _revision = 0;

  PetAnimation get current => _override ?? _current;

  int get revision => _revision;

  Pet get pet => _pet;

  /// Replace the underlying pet. Used when the user picks a
  /// different pet on the settings tab — the new pet may have a
  /// different animation table, so we reset to its default.
  void setPet(Pet pet) {
    _pet = pet;
    _current =
        pet.animationByName(pet.defaultAnimation) ??
        (pet.animations.isNotEmpty ? pet.animations.first : _missingAnimation);
    _override = null;
    _oneShotRepeatsRemaining = 0;
    _revision++;
    notifyListeners();
  }

  /// Play [name] once and then fall back to the pet's default
  /// looping animation. If [name] isn't a known animation on the
  /// current pet (e.g. an importer left it out), the call is a
  /// silent no-op — the pet stays in its default animation.
  void playOneShot(String name, {int repeats = 1}) {
    final animation = _pet.animationByName(name);
    if (animation == null || repeats < 1) return;
    _current = animation;
    _oneShotRepeatsRemaining = repeats;
    _revision++;
    notifyListeners();
  }

  /// Switch into a looping [name]. Stays until something else
  /// takes over. Same silent-no-op semantics as [playOneShot].
  void playLooping(String name) {
    final animation = _pet.animationByName(name);
    if (animation == null) return;
    _current = animation;
    _oneShotRepeatsRemaining = 0;
    _revision++;
    notifyListeners();
  }

  void forceLooping(String name) {
    final animation = _pet.animationByName(name);
    if (animation == null) return;
    _override = PetAnimation(
      name: animation.name,
      row: animation.row,
      frameCount: animation.frameCount,
      loop: true,
    );
    _revision++;
    notifyListeners();
  }

  void clearForce() {
    if (_override == null) return;
    _override = null;
    _revision++;
    notifyListeners();
  }

  /// Return to the pet's default animation immediately.
  void reset() {
    final fallback = _pet.animationByName(_pet.defaultAnimation);
    if (fallback == null) return;
    _current = fallback;
    _oneShotRepeatsRemaining = 0;
    _revision++;
    notifyListeners();
  }

  /// Hook for the widget to signal that a one-shot has finished
  /// playing. The renderer calls this from its
  /// `AnimationController.addStatusListener` so we drop back to
  /// the default animation. Looping animations never trigger this
  /// (they `repeat()` forever), so calling [reset] is a no-op for
  /// them.
  void notifyOneShotCompleted() {
    if (_oneShotRepeatsRemaining > 1) {
      _oneShotRepeatsRemaining--;
      _revision++;
      notifyListeners();
      return;
    }
    final fallback = _pet.animationByName(_pet.defaultAnimation);
    if (fallback == null) return;
    if (_current == fallback) return;
    _current = fallback;
    _oneShotRepeatsRemaining = 0;
    _revision++;
    notifyListeners();
  }
}
