import 'dart:io';

import 'package:agent_buddy/services/pet_window_state_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pet_window_state_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('returns null before a position is saved', () async {
    final store = PetWindowStateStore(appDir: tempDir);
    expect(await store.loadPosition(), isNull);
  });

  test('saves and restores the window position', () async {
    final store = PetWindowStateStore(appDir: tempDir);
    const position = Offset(123.5, 456.25);
    await store.savePosition(position);
    expect(await store.loadPosition(), position);
  });

  test('serializes concurrent position saves', () async {
    final store = PetWindowStateStore(appDir: tempDir);
    const positions = [Offset(10, 20), Offset(30, 40), Offset(50, 60)];
    await Future.wait(positions.map(store.savePosition));
    expect(await store.loadPosition(), positions.last);
  });

  test('ignores malformed state files', () async {
    final pets = Directory('${tempDir.path}${Platform.pathSeparator}pets');
    await pets.create(recursive: true);
    await File(
      '${pets.path}${Platform.pathSeparator}window_state.json',
    ).writeAsString('invalid');
    final store = PetWindowStateStore(appDir: tempDir);
    expect(await store.loadPosition(), isNull);
  });
}
