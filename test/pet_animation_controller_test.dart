import 'package:agent_buddy/models/pet.dart';
import 'package:agent_buddy/services/pet_animation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Pet buildPet() {
    return Pet(
      id: 'p',
      displayName: 'P',
      description: 'd',
      spritesheetRelPath: 'sheet.webp',
      frameWidth: 100,
      frameHeight: 100,
      fps: 4,
      animations: const [
        PetAnimation(name: 'idle', row: 0, frameCount: 6, loop: true),
        PetAnimation(name: 'waving', row: 1, frameCount: 4, loop: false),
        PetAnimation(name: 'jumping', row: 2, frameCount: 5, loop: false),
        PetAnimation(name: 'review', row: 3, frameCount: 6, loop: true),
      ],
      defaultAnimation: 'idle',
    );
  }

  test('starts on the pet default animation', () {
    final ctrl = PetAnimationController(pet: buildPet());
    expect(ctrl.current.name, 'idle');
    ctrl.dispose();
  });

  test('playOneShot switches to the named animation', () {
    final ctrl = PetAnimationController(pet: buildPet());
    ctrl.playOneShot('jumping');
    expect(ctrl.current.name, 'jumping');
    ctrl.dispose();
  });

  test('playOneShot is a silent no-op for unknown names', () {
    final ctrl = PetAnimationController(pet: buildPet());
    ctrl.playOneShot('does_not_exist');
    expect(ctrl.current.name, 'idle');
    ctrl.dispose();
  });

  test('playLooping switches to the named looping animation', () {
    final ctrl = PetAnimationController(pet: buildPet());
    ctrl.playLooping('review');
    expect(ctrl.current.name, 'review');
    ctrl.dispose();
  });

  test('reset returns to the pet default animation', () {
    final ctrl = PetAnimationController(pet: buildPet());
    ctrl.playLooping('review');
    expect(ctrl.current.name, 'review');
    ctrl.reset();
    expect(ctrl.current.name, 'idle');
    ctrl.dispose();
  });

  test('notifyOneShotCompleted falls back to the default', () {
    final ctrl = PetAnimationController(pet: buildPet());
    ctrl.playOneShot('jumping');
    expect(ctrl.current.name, 'jumping');
    ctrl.notifyOneShotCompleted();
    expect(ctrl.current.name, 'idle');
    ctrl.dispose();
  });

  test('setPet replaces the underlying pet and resets to its default', () {
    final ctrl = PetAnimationController(pet: buildPet());
    ctrl.playLooping('review');
    final other = Pet(
      id: 'q',
      displayName: 'Q',
      description: '',
      spritesheetRelPath: 'sheet.webp',
      frameWidth: 100,
      frameHeight: 100,
      fps: 4,
      animations: const [
        PetAnimation(name: 'sleeping', row: 0, frameCount: 4, loop: true),
      ],
      defaultAnimation: 'sleeping',
    );
    ctrl.setPet(other);
    expect(ctrl.pet.id, 'q');
    expect(ctrl.current.name, 'sleeping');
    ctrl.dispose();
  });

  test('listeners fire on every animation change', () {
    final ctrl = PetAnimationController(pet: buildPet());
    var fires = 0;
    ctrl.addListener(() => fires++);
    ctrl.playOneShot('jumping');
    ctrl.playLooping('review');
    ctrl.reset();
    expect(fires, 3);
    ctrl.dispose();
  });
}