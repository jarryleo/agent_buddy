import '../services/pet_window_controller.dart';

/// Side-effect interface the chat provider uses to drive the
/// desktop pet's reaction animations. The production wiring
/// passes a [PetWindowController] (which fans the calls out over
/// the multi-window IPC); tests pass a fake that just records
/// the calls so they can assert the right sequence.
///
/// Three channels:
///   * [playLooping] — model is thinking / streaming / running a
///     tool. The pet plays an ambient looping animation.
///   * [playOneShot] — discrete events (tool success, tool
///     failure). The pet plays a one-shot then drops back to its
///     default.
///   * [reset] — return to the default animation. Called when a
///     turn ends, the user stops typing, or the pet's drag
///     override releases.
///
/// All three methods MUST be safe to call when the pet window is
/// not currently shown — they should silently no-op rather than
/// throw so the chat flow doesn't have to gate every call.
abstract class PetAnimationHooks {
  Future<void> playLooping(String name);
  Future<void> playOneShot(String name);
  Future<void> reset();
}

/// Adapter that forwards calls into a [PetWindowController]. The
/// pet controller handles the "window is hidden" case itself, so
/// the adapter is a thin pass-through.
class _PetWindowHooksAdapter implements PetAnimationHooks {
  _PetWindowHooksAdapter(this._controller);
  final PetWindowController _controller;

  @override
  Future<void> playLooping(String name) => _controller.playLooping(name);

  @override
  Future<void> playOneShot(String name) => _controller.playOneShot(name);

  @override
  Future<void> reset() => _controller.reset();
}

PetAnimationHooks? petAnimationHooksFromController(
  PetWindowController? controller,
) {
  if (controller == null) return null;
  return _PetWindowHooksAdapter(controller);
}