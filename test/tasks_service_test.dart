import 'dart:io';

import 'package:agent_buddy/models/task_adapter.dart';
import 'package:agent_buddy/services/platform/tasks_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late TasksService service;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(TaskAdapter());
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_tasks_test_');
    Hive.init(tempDir.path);
    service = TasksService();
    await service.open();
  });

  tearDown(() async {
    await service.close();
    await Hive.deleteBoxFromDisk(TasksService.boxName);
    await tempDir.delete(recursive: true);
  });

  test('list is empty on a fresh store', () {
    expect(service.list(), isEmpty);
  });

  test('create + get round-trips a task', () async {
    final t = await service.create(title: 'Pay rent', notes: 'before 5th');
    expect(t.title, 'Pay rent');
    expect(t.completed, isFalse);
    final fetched = service.get(t.id);
    expect(fetched, isNotNull);
    expect(fetched!.notes, 'before 5th');
  });

  test('list excludes completed by default', () async {
    final a = await service.create(title: 'a', notes: null);
    final b = await service.create(title: 'b', notes: null);
    final c = await service.create(title: 'c', notes: null);
    await service.complete(b.id);
    final pending = service.list();
    expect(pending.map((t) => t.id).toSet(), {a.id, c.id});
    final all = service.list(includeCompleted: true);
    expect(all.length, 3);
  });

  test('complete marks task done and stamps completedAt', () async {
    final t = await service.create(title: 'x', notes: null);
    final done = await service.complete(t.id);
    expect(done, isNotNull);
    expect(done!.completed, isTrue);
    expect(done.completedAt, isNotNull);
  });

  test('complete returns null on unknown id', () async {
    final r = await service.complete('nope');
    expect(r, isNull);
  });

  test('update changes fields and bumps updatedAt', () async {
    final t = await service.create(title: 'old', notes: null);
    final updated = await service.update(
      id: t.id,
      title: 'new',
      notes: 'extra',
    );
    expect(updated, isNotNull);
    expect(updated!.title, 'new');
    expect(updated.notes, 'extra');
  });

  test('list sorts by due ascending (no-due tasks last)', () async {
    final noDue = await service.create(title: 'no-due', notes: null);
    final soon = await service.create(
      title: 'soon',
      notes: null,
      due: DateTime.now().add(const Duration(days: 1)),
    );
    final later = await service.create(
      title: 'later',
      notes: null,
      due: DateTime.now().add(const Duration(days: 30)),
    );
    final items = service.list();
    expect(items.map((t) => t.id).toList(), [soon.id, later.id, noDue.id]);
  });

  test('delete removes the task and returns true', () async {
    final t = await service.create(title: 'doomed', notes: null);
    expect(await service.delete(t.id), isTrue);
    expect(service.get(t.id), isNull);
  });

  test('list truncates to max', () async {
    for (var i = 0; i < 5; i++) {
      await service.create(title: 't$i', notes: null);
    }
    expect(service.list(max: 2).length, 2);
  });
}
