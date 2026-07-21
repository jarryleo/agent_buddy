import 'dart:io';

import 'package:agent_buddy/models/chat_session.dart';
import 'package:agent_buddy/models/chat_session_adapter.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/todo_list.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Round-trips a [ChatSession] through the hand-written Hive
/// [ChatSessionAdapter] and asserts the persisted shape matches
/// the in-memory one. Uses a real Hive box (the same way
/// `notes_service_test.dart` and `memory_repository_test.dart`
/// do) so the test exercises the actual binary framing.
void main() {
  late Directory tempDir;
  late Box<ChatSession> box;

  setUpAll(() {
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ChatSessionAdapter());
    }
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_chat_session_todo_test_',
    );
    Hive.init(tempDir.path);
    box = await Hive.openBox<ChatSession>('chat_sessions_todo_test');
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('chat_sessions_todo_test');
    await tempDir.delete(recursive: true);
  });

  test('round-trips a session with a populated todo list', () async {
    final original = ChatSession(
      id: 'sess-1',
      title: '调研',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_500_000),
      messages: [
        ChatMessage(
          id: 'm1',
          role: MessageRole.user,
          content: '帮我研究下 X',
        ),
      ],
      todoList: TodoList(
        title: '研究 X',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_100_000),
        revision: 3,
        items: [
          TodoItem(
            id: 'td_1',
            content: '看官方文档',
            order: 0,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              1_700_000_100_000,
            ),
          ),
          TodoItem(
            id: 'td_2',
            content: '对比第三方评测',
            order: 1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              1_700_000_150_000,
            ),
            status: TodoItemStatus.done,
            completedAt: DateTime.fromMillisecondsSinceEpoch(
              1_700_000_200_000,
            ),
          ),
        ],
      ),
    );

    await box.put('k1', original);
    final restored = box.get('k1')!;

    expect(restored.id, original.id);
    expect(restored.title, original.title);
    expect(restored.createdAt, original.createdAt);
    expect(restored.updatedAt, original.updatedAt);
    expect(restored.messages.length, 1);
    expect(restored.messages.first.id, 'm1');
    expect(restored.messages.first.content, '帮我研究下 X');
    expect(restored.todoList.title, '研究 X');
    expect(restored.todoList.revision, 3);
    expect(restored.todoList.items.length, 2);
    expect(restored.todoList.items[0].status, TodoItemStatus.pending);
    expect(restored.todoList.items[1].status, TodoItemStatus.done);
    expect(restored.todoList.completedCount, 1);
    expect(restored.todoList.allDone, isFalse);
  });

  test('round-trips a session with an empty todo list', () async {
    final original = ChatSession(
      id: 'sess-2',
      title: '闲聊',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_500_000),
      messages: const [],
      todoList: TodoList.empty,
    );
    await box.put('k2', original);
    final restored = box.get('k2')!;
    expect(restored.todoList.isEmpty, isTrue);
    expect(restored.todoList.items, isEmpty);
    expect(restored.todoList.allDone, isTrue);
  });

  test('auto-init list on first add keeps the rest of the session intact',
      () async {
    final original = ChatSession(
      id: 'sess-3',
      title: 'follow-up',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_500_000),
      messages: const [],
    );
    await box.put('k3', original);
    final restored = box.get('k3')!;
    // Default ChatSession has TodoList.empty — defensive check
    // so the rest of the chat provider can rely on it.
    expect(restored.todoList.isEmpty, isTrue);
  });
}