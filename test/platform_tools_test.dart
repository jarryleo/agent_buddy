import 'dart:io';

import 'package:agent_buddy/models/note.dart';
import 'package:agent_buddy/models/note_adapter.dart';
import 'package:agent_buddy/models/task.dart';
import 'package:agent_buddy/models/task_adapter.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late Box<Note> notesBox;
  late Box<Task> tasksBox;
  late ToolService tools;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(NoteAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(TaskAdapter());
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_tools_test_');
    Hive.init(tempDir.path);
    notesBox = await Hive.openBox<Note>('notes');
    tasksBox = await Hive.openBox<Task>('tasks');
    tools = ToolService(notesBox: notesBox, tasksBox: tasksBox);
  });

  tearDown(() async {
    await notesBox.close();
    await tasksBox.close();
    await Hive.deleteBoxFromDisk('notes');
    await Hive.deleteBoxFromDisk('tasks');
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
}

String _extractId(String json) {
  // Tiny, dep-free extractor for `"id":"<value>"` in the envelope.
  final re = RegExp('"id":\\s*"([^"]+)"');
  final m = re.firstMatch(json);
  if (m == null) fail('no id in envelope: $json');
  return m.group(1)!;
}
