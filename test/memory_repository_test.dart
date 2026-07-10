import 'dart:io';

import 'package:agent_buddy/models/memory.dart';
import 'package:agent_buddy/models/memory_adapter.dart';
import 'package:agent_buddy/services/memory_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late Box<Memory> box;
  late MemoryRepository repo;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(MemoryAdapter());
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_memory_repo_test_',
    );
    Hive.init(tempDir.path);
    box = await Hive.openBox<Memory>(MemoryRepository.boxName);
    repo = MemoryRepository()..open(preopened: box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk(MemoryRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test('add then list returns the memory sorted newest-first', () async {
    final first = await repo.add(
      content: 'first',
      source: 'user',
      createdAt: DateTime(2024, 1, 1),
    );
    final second = await repo.add(
      content: 'second',
      source: 'ai',
      createdAt: DateTime(2024, 1, 2),
    );
    final all = repo.list();
    expect(all.length, 2);
    expect(all.first.id, second.id);
    expect(all.last.id, first.id);
  });

  test('list with keyword does a case-insensitive contains match', () async {
    await repo.add(content: 'User prefers Dark Mode', source: 'ai');
    await repo.add(content: 'Lives in Shanghai', source: 'ai');
    await repo.add(content: 'Dislikes cilantro', source: 'user');

    final hits = repo.list(keyword: 'shang');
    expect(hits.length, 1);
    expect(hits.first.content, contains('Shanghai'));

    final mixed = repo.list(keyword: 'DARK');
    expect(mixed.length, 1);
    expect(mixed.first.content, contains('Dark Mode'));
  });

  test('list with empty keyword behaves like unfiltered', () async {
    await repo.add(content: 'a', source: 'ai');
    await repo.add(content: 'b', source: 'ai');
    final all = repo.list(keyword: '');
    expect(all.length, 2);
  });

  test('list respects max truncation', () async {
    for (var i = 0; i < 5; i++) {
      await repo.add(content: 'mem-$i', source: 'ai');
    }
    final limited = repo.list(max: 3);
    expect(limited.length, 3);
  });

  test(
    'get returns null for missing id and the value for a real one',
    () async {
      final added = await repo.add(content: 'lookup me', source: 'user');
      expect(repo.get(added.id), isNotNull);
      expect(repo.get(''), isNull);
      expect(repo.get('does-not-exist'), isNull);
    },
  );

  test('update changes content and source, keeps id', () async {
    final m = await repo.add(content: 'before', source: 'user');
    final updated = await repo.update(id: m.id, content: 'after', source: 'ai');
    expect(updated, isNotNull);
    expect(updated!.id, m.id);
    expect(updated.content, 'after');
    expect(updated.source, 'ai');
    final fetched = repo.get(m.id);
    expect(fetched!.content, 'after');
  });

  test('update returns null for missing id', () async {
    final result = await repo.update(id: 'nope', content: 'x');
    expect(result, isNull);
  });

  test(
    'delete removes a single memory and returns false for unknowns',
    () async {
      final m = await repo.add(content: 'goodbye', source: 'user');
      expect(await repo.delete(m.id), isTrue);
      expect(repo.get(m.id), isNull);
      expect(await repo.delete('nope'), isFalse);
    },
  );

  test('deleteMany removes the listed ids and tolerates unknowns', () async {
    final a = await repo.add(content: 'a', source: 'user');
    final b = await repo.add(content: 'b', source: 'user');
    final c = await repo.add(content: 'c', source: 'user');
    await repo.deleteMany([a.id, c.id, 'does-not-exist']);
    expect(repo.length, 1);
    expect(repo.get(b.id), isNotNull);
  });
}
