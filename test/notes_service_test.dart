import 'dart:io';

import 'package:agent_buddy/models/note_adapter.dart';
import 'package:agent_buddy/services/platform/notes_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late NotesService service;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(NoteAdapter());
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_notes_test_');
    Hive.init(tempDir.path);
    service = NotesService();
    await service.open();
  });

  tearDown(() async {
    await service.close();
    await Hive.deleteBoxFromDisk(NotesService.boxName);
    await tempDir.delete(recursive: true);
  });

  test('list is empty on a fresh store', () {
    expect(service.list(), isEmpty);
  });

  test('create + get round-trips a note', () async {
    final n = await service.create(title: 'Shopping', content: 'eggs, milk');
    expect(n.title, 'Shopping');
    expect(n.content, 'eggs, milk');
    expect(n.id, isNotEmpty);
    final fetched = service.get(n.id);
    expect(fetched, isNotNull);
    expect(fetched!.title, 'Shopping');
  });

  test('list returns notes newest-first by updatedAt', () async {
    final a = await service.create(title: 'a', content: '');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final b = await service.create(title: 'b', content: '');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final c = await service.create(title: 'c', content: '');
    final all = service.list();
    expect(all.map((n) => n.id).toList(), [c.id, b.id, a.id]);
  });

  test('list filters by keyword (title or content)', () async {
    await service.create(title: 'Shopping list', content: 'eggs');
    await service.create(title: 'Workout', content: 'pushups, run');
    await service.create(title: 'Reading', content: 'shopping cart essay');
    final hits = service.list(keyword: 'shopping');
    expect(hits.length, 2);
  });

  test('update changes fields and bumps updatedAt', () async {
    final n = await service.create(title: 'old', content: 'old body');
    final updated = await service.update(
      id: n.id,
      title: 'new',
      content: 'new body',
    );
    expect(updated, isNotNull);
    expect(updated!.title, 'new');
    expect(updated.content, 'new body');
    expect(
      updated.updatedAt.isAfter(n.updatedAt) ||
          updated.updatedAt.isAtSameMomentAs(n.updatedAt),
      isTrue,
    );
  });

  test('update returns null on unknown id', () async {
    final r = await service.update(id: 'nope', title: 'x');
    expect(r, isNull);
  });

  test('delete removes the note and returns true', () async {
    final n = await service.create(title: 'doomed', content: '');
    expect(await service.delete(n.id), isTrue);
    expect(service.get(n.id), isNull);
  });

  test('delete returns false on unknown id', () async {
    expect(await service.delete('nope'), isFalse);
  });

  test('list truncates to max', () async {
    for (var i = 0; i < 5; i++) {
      await service.create(title: 'n$i', content: '');
    }
    final items = service.list(max: 2);
    expect(items.length, 2);
  });
}
