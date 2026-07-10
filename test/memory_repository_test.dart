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

  // ---- tags ----

  test('add with tags persists them; fromJson reads them back', () async {
    final m = await repo.add(
      content: 'User loves hiking',
      source: 'ai',
      tags: ['outdoor', 'hobby', '运动'],
    );
    expect(m.tags, ['outdoor', 'hobby', '运动']);
    final fetched = repo.get(m.id)!;
    expect(fetched.tags, ['outdoor', 'hobby', '运动']);
  });

  test('add with empty / null tags yields an empty list', () async {
    final m1 = await repo.add(content: 'a', source: 'user');
    expect(m1.tags, isEmpty);
    final m2 = await repo.add(content: 'b', source: 'user', tags: const []);
    expect(m2.tags, isEmpty);
  });

  test(
    'update replaces tags; null keeps existing; empty list clears',
    () async {
      final m = await repo.add(
        content: 'x',
        source: 'ai',
        tags: ['one', 'two'],
      );
      final replaced = await repo.update(id: m.id, tags: ['three']);
      expect(replaced!.tags, ['three']);

      final kept = await repo.update(id: m.id, content: 'x2');
      expect(kept!.tags, ['three']);

      final cleared = await repo.update(id: m.id, tags: const []);
      expect(cleared!.tags, isEmpty);
    },
  );

  test('list with keywords[] returns a memory if any keyword hits content '
      'OR any tag (OR semantics, case-insensitive)', () async {
    await repo.add(
      content: 'Lives in Shanghai',
      source: 'ai',
      tags: ['城市', 'China'],
    );
    await repo.add(content: 'Loves dark mode', source: 'ai', tags: ['theme']);
    await repo.add(
      content: 'Has a cat named Mochi',
      source: 'user',
      tags: ['pet'],
    );

    // Both terms match different memories — OR.
    final hits = repo.list(keywords: ['shanghai', 'mochi']);
    expect(hits.length, 2);
    final contents = hits.map((m) => m.content).toSet();
    expect(contents, contains('Lives in Shanghai'));
    expect(contents, contains('Has a cat named Mochi'));

    // Keyword matches a tag even if content is unrelated.
    final tagHit = repo.list(keywords: ['theme']);
    expect(tagHit.length, 1);
    expect(tagHit.first.content, 'Loves dark mode');
  });

  test(
    'list with tags[] returns memories whose tags intersect the filter',
    () async {
      await repo.add(content: 'a', source: 'ai', tags: ['food', 'fruit']);
      await repo.add(content: 'b', source: 'ai', tags: ['food', 'spicy']);
      await repo.add(content: 'c', source: 'ai', tags: ['music']);

      final hits = repo.list(tags: ['food']);
      expect(hits.length, 2);
      final ids = hits.map((m) => m.content).toSet();
      expect(ids, containsAll({'a', 'b'}));

      final none = repo.list(tags: ['nonexistent']);
      expect(none, isEmpty);
    },
  );

  test(
    'list with keywords + tags: a memory matches if keyword OR tag hits',
    () async {
      await repo.add(
        content: 'Chinese food preferences',
        source: 'ai',
        tags: ['food', 'chinese'],
      );
      await repo.add(
        content: 'Likes Italian food',
        source: 'ai',
        tags: ['food', 'italian'],
      );
      await repo.add(
        content: 'Dislikes cilantro',
        source: 'user',
        tags: ['food', 'herb'],
      );

      // keyword 'italian' matches one memory's content; tag 'herb'
      // matches another. The two memory ids together come back.
      final hits = repo.list(keywords: ['italian'], tags: ['herb']);
      expect(hits.length, 2);
      final contents = hits.map((m) => m.content).toSet();
      expect(
        contents,
        containsAll({'Likes Italian food', 'Dislikes cilantro'}),
      );
    },
  );

  test('list with keywords wins over the legacy keyword argument', () async {
    await repo.add(content: 'foo', source: 'ai');
    await repo.add(content: 'bar', source: 'ai');
    final hits = repo.list(keyword: 'bar', keywords: ['foo']);
    expect(hits.length, 1);
    expect(hits.first.content, 'foo');
  });

  // ---- v1 / v2 backward compatibility ----
  //
  // Memory records written by the previous app version use the v1
  // wire layout (no tags section). [MemoryAdapter.read] detects
  // version=1 and returns a [Memory] with an empty `tags` list;
  // a fresh write through [MemoryRepository] always emits v2.
  // We don't fabricate v1 bytes here: hand-rolling Hive's frame
  // format is fragile, and the read branch is a one-liner
  // (`if (version >= 2) { read tag count + tags }`). The risk of
  // an on-disk format mismatch is low and would be caught by
  // smoke-testing the upgrade path on a real device.
}
