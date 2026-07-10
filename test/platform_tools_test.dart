import 'dart:io';

import 'package:agent_buddy/models/memory.dart';
import 'package:agent_buddy/models/memory_adapter.dart';
import 'package:agent_buddy/models/note.dart';
import 'package:agent_buddy/models/note_adapter.dart';
import 'package:agent_buddy/models/task.dart';
import 'package:agent_buddy/models/task_adapter.dart';
import 'package:agent_buddy/services/memory_repository.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late Box<Note> notesBox;
  late Box<Task> tasksBox;
  late Box<Memory> memoriesBox;
  late ToolService tools;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(NoteAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(TaskAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(MemoryAdapter());
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_tools_test_');
    Hive.init(tempDir.path);
    notesBox = await Hive.openBox<Note>('notes');
    tasksBox = await Hive.openBox<Task>('tasks');
    memoriesBox = await Hive.openBox<Memory>(MemoryRepository.boxName);
    tools = ToolService(
      notesBox: notesBox,
      tasksBox: tasksBox,
      memoriesBox: memoriesBox,
    );
  });

  tearDown(() async {
    await notesBox.close();
    await tasksBox.close();
    await memoriesBox.close();
    await Hive.deleteBoxFromDisk('notes');
    await Hive.deleteBoxFromDisk('tasks');
    await Hive.deleteBoxFromDisk(MemoryRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  group('runNotes', () {
    test('action=list returns empty envelope', () async {
      final raw = await tools.runNotes({'action': 'list'});
      expect(raw, contains('"action":"list"'));
      expect(raw, contains('"count":0'));
    });

    test('action=create then list returns it', () async {
      await tools.runNotes({
        'action': 'create',
        'title': 'todo',
        'content': 'buy milk',
      });
      final raw = await tools.runNotes({'action': 'list'});
      expect(raw, contains('buy milk'));
    });

    test('action=create requires title', () async {
      expect(
        () => tools.runNotes({'action': 'create', 'content': 'x'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('action=update changes fields', () async {
      final created = await tools.runNotes({
        'action': 'create',
        'title': 'old',
        'content': 'old',
      });
      // Pull the id back from the JSON envelope.
      final id = _extractId(created);
      await tools.runNotes({'action': 'update', 'id': id, 'title': 'new'});
      final fetched = await tools.runNotes({'action': 'get', 'id': id});
      expect(fetched, contains('"title":"new"'));
    });

    test('action=get on unknown id returns found:false', () async {
      final raw = await tools.runNotes({'action': 'get', 'id': 'missing'});
      expect(raw, contains('"found":false'));
    });

    test('action=delete removes the note', () async {
      final created = await tools.runNotes({
        'action': 'create',
        'title': 'doomed',
        'content': '',
      });
      final id = _extractId(created);
      final raw = await tools.runNotes({'action': 'delete', 'id': id});
      expect(raw, contains('"ok":true'));
      final after = await tools.runNotes({'action': 'get', 'id': id});
      expect(after, contains('"found":false'));
    });

    test('unknown action throws ToolException', () async {
      expect(
        () => tools.runNotes({'action': 'explode'}),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('runTasks', () {
    test('create + list returns the task', () async {
      await tools.runTasks({
        'action': 'create',
        'title': 'Pay rent',
        'notes': '5th',
      });
      final raw = await tools.runTasks({'action': 'list'});
      expect(raw, contains('Pay rent'));
    });

    test('complete marks it done; default list omits it', () async {
      final created = await tools.runTasks({
        'action': 'create',
        'title': 'trash',
        'notes': null,
      });
      final id = _extractId(created);
      await tools.runTasks({'action': 'complete', 'id': id});
      final raw = await tools.runTasks({'action': 'list'});
      expect(raw, contains('"count":0'));
      final all = await tools.runTasks({
        'action': 'list',
        'include_completed': true,
      });
      expect(all, contains('"completed":true'));
    });

    test('action=create requires title', () async {
      expect(
        () => tools.runTasks({'action': 'create'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('unknown action throws ToolException', () async {
      expect(
        () => tools.runTasks({'action': 'nope'}),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('runMemory', () {
    test('create writes source=ai and list returns it', () async {
      final created = await tools.runMemory({
        'action': 'create',
        'content': 'User prefers dark mode',
      });
      expect(created, contains('"action":"create"'));
      expect(created, contains('"source":"ai"'));
      final list = await tools.runMemory({'action': 'list'});
      expect(list, contains('"count":1'));
      expect(list, contains('dark mode'));
    });

    test('search with keyword does fuzzy match', () async {
      await tools.runMemory({
        'action': 'create',
        'content': 'Lives in Shanghai',
      });
      await tools.runMemory({
        'action': 'create',
        'content': 'Dislikes cilantro',
      });
      final hits = await tools.runMemory({
        'action': 'search',
        'keyword': 'SHANG',
      });
      expect(hits, contains('"action":"search"'));
      expect(hits, contains('"count":1'));
      expect(hits, contains('Shanghai'));
    });

    test('search requires keyword', () async {
      expect(
        () => tools.runMemory({'action': 'search'}),
        throwsA(isA<ToolException>()),
      );
      expect(
        () => tools.runMemory({'action': 'search', 'keyword': '   '}),
        throwsA(isA<ToolException>()),
      );
    });

    test('create requires content', () async {
      expect(
        () => tools.runMemory({'action': 'create'}),
        throwsA(isA<ToolException>()),
      );
      expect(
        () => tools.runMemory({'action': 'create', 'content': '  '}),
        throwsA(isA<ToolException>()),
      );
    });

    test('get unknown id returns found:false', () async {
      final raw = await tools.runMemory({'action': 'get', 'id': 'missing'});
      expect(raw, contains('"found":false'));
    });

    test('delete_batch removes the listed ids', () async {
      final a = await tools.runMemory({'action': 'create', 'content': 'a'});
      final b = await tools.runMemory({'action': 'create', 'content': 'b'});
      final c = await tools.runMemory({'action': 'create', 'content': 'c'});
      final ids = [_extractId(a), _extractId(c), 'nope'];
      final raw = await tools.runMemory({'action': 'delete_batch', 'ids': ids});
      expect(raw, contains('"ok":true'));
      final list = await tools.runMemory({'action': 'list'});
      expect(list, contains('"count":1'));
      expect(list, contains('"id":"${_extractId(b)}"'));
    });

    test('delete_batch with empty ids throws', () async {
      expect(
        () => tools.runMemory({'action': 'delete_batch', 'ids': []}),
        throwsA(isA<ToolException>()),
      );
    });

    test('unknown action throws ToolException', () async {
      expect(
        () => tools.runMemory({'action': 'explode'}),
        throwsA(isA<ToolException>()),
      );
    });

    test('create persists tags and they appear in the envelope', () async {
      final raw = await tools.runMemory({
        'action': 'create',
        'content': 'Lives in Shanghai',
        'tags': ['city', '上海', 'China', 'location'],
      });
      expect(raw, contains('"tags":'));
      expect(raw, contains('city'));
      expect(raw, contains('上海'));
    });

    test('search with keywords[] OR-matches content or tags', () async {
      await tools.runMemory({
        'action': 'create',
        'content': 'Lives in Shanghai',
        'tags': ['city', '上海'],
      });
      await tools.runMemory({
        'action': 'create',
        'content': 'Loves dark mode',
        'tags': ['theme'],
      });
      final hits = await tools.runMemory({
        'action': 'search',
        'keywords': ['shanghai', 'theme'],
      });
      expect(hits, contains('"action":"search"'));
      expect(hits, contains('"keywords":'));
      expect(hits, contains('"count":2'));
      expect(hits, contains('Lives in Shanghai'));
      expect(hits, contains('Loves dark mode'));
    });

    test(
      'search with keyword (singular) still works for backward compat',
      () async {
        await tools.runMemory({
          'action': 'create',
          'content': 'Lives in Shanghai',
          'tags': ['city'],
        });
        final hits = await tools.runMemory({
          'action': 'search',
          'keyword': 'shanghai',
        });
        expect(hits, contains('"count":1'));
      },
    );

    test('search with no keywords and no tags throws', () async {
      expect(
        () => tools.runMemory({'action': 'search'}),
        throwsA(isA<ToolException>()),
      );
      expect(
        () => tools.runMemory({'action': 'search', 'keywords': [], 'tags': []}),
        throwsA(isA<ToolException>()),
      );
    });

    test(
      'search with tags[] alone (no keywords) works for tag-only lookup',
      () async {
        await tools.runMemory({
          'action': 'create',
          'content': 'prefers spicy food',
          'tags': ['food', 'spicy'],
        });
        await tools.runMemory({
          'action': 'create',
          'content': 'likes classical music',
          'tags': ['music'],
        });
        final hits = await tools.runMemory({
          'action': 'search',
          'tags': ['food'],
        });
        expect(hits, contains('"count":1'));
        expect(hits, contains('prefers spicy food'));
      },
    );

    test(
      'search with tags[] filters to memories whose tags intersect',
      () async {
        await tools.runMemory({
          'action': 'create',
          'content': 'prefers spicy food',
          'tags': ['food', 'spicy'],
        });
        await tools.runMemory({
          'action': 'create',
          'content': 'likes classical music',
          'tags': ['music'],
        });
        final hits = await tools.runMemory({
          'action': 'search',
          'tags': ['food'],
        });
        expect(hits, contains('"count":1'));
        expect(hits, contains('prefers spicy food'));
      },
    );

    test('update replaces content and tags; null keeps existing', () async {
      final created = await tools.runMemory({
        'action': 'create',
        'content': 'old content',
        'tags': ['old'],
      });
      final id = _extractId(created);
      final updated = await tools.runMemory({
        'action': 'update',
        'id': id,
        'content': 'new content',
        'tags': ['new1', 'new2'],
      });
      expect(updated, contains('"content":"new content"'));
      expect(updated, contains('new1'));
      expect(updated, contains('new2'));
      expect(updated, isNot(contains('old')));
    });

    test('update on unknown id returns found:false', () async {
      final raw = await tools.runMemory({
        'action': 'update',
        'id': 'missing',
        'content': 'x',
      });
      expect(raw, contains('"found":false'));
    });
  });
}

String _extractId(String json) {
  // Tiny, dep-free extractor for `"id":"<value>"` in the envelope.
  final re = RegExp('"id":\\s*"([^"]+)"');
  final m = re.firstMatch(json);
  if (m == null) fail('no id in envelope: $json');
  return m.group(1)!;
}
