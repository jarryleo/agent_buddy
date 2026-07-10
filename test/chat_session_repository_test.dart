import 'dart:io';

import 'package:agent_buddy/models/chat_session.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory tempDir;
  late ChatSessionRepository repo;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_hive_test_');
    Hive.init(tempDir.path);
    repo = ChatSessionRepository();
    await repo.open();
  });

  tearDown(() async {
    await repo.close();
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test('empty store returns no sessions', () {
    expect(repo.length, 0);
    expect(repo.list(), isEmpty);
  });

  test('save + get round-trips a session with messages', () async {
    final now = DateTime.now();
    final session = ChatSession(
      id: 's1',
      title: 'Hello',
      createdAt: now,
      updatedAt: now,
      messages: [
        ChatMessage(
          id: 'm1',
          role: MessageRole.user,
          content: 'Hi',
          createdAt: now,
        ),
        ChatMessage(
          id: 'm2',
          role: MessageRole.assistant,
          content: 'Hello!',
          createdAt: now,
        ),
      ],
    );
    await repo.save(session);

    final loaded = repo.get('s1');
    expect(loaded, isNotNull);
    expect(loaded!.id, 's1');
    expect(loaded.title, 'Hello');
    expect(loaded.messages, hasLength(2));
    expect(loaded.messages[0].role, MessageRole.user);
    expect(loaded.messages[0].content, 'Hi');
    expect(loaded.messages[1].role, MessageRole.assistant);
    expect(loaded.messages[1].content, 'Hello!');
  });

  test('list returns newest-first', () async {
    final older = DateTime(2025, 1, 1);
    final newer = DateTime(2026, 1, 1);
    await repo.save(
      ChatSession(
        id: 'older',
        title: 'Old',
        createdAt: older,
        updatedAt: older,
      ),
    );
    await repo.save(
      ChatSession(
        id: 'newer',
        title: 'New',
        createdAt: newer,
        updatedAt: newer,
      ),
    );
    final list = repo.list();
    expect(list.map((s) => s.id), ['newer', 'older']);
  });

  test('delete removes a session', () async {
    final s = ChatSession(
      id: 'gone',
      title: 'Trash me',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await repo.save(s);
    expect(repo.get('gone'), isNotNull);
    await repo.delete('gone');
    expect(repo.get('gone'), isNull);
    expect(repo.length, 0);
  });

  test('deleteMany swallows missing ids and removes the rest', () async {
    for (var i = 0; i < 3; i++) {
      await repo.save(
        ChatSession(
          id: 'm$i',
          title: 'm$i',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
    await repo.deleteMany(['m0', 'does-not-exist', 'm2']);
    expect(repo.get('m0'), isNull);
    expect(repo.get('m1'), isNotNull);
    expect(repo.get('m2'), isNull);
  });

  test(
    'updateMessages rewrites the message list and bumps updatedAt',
    () async {
      final t0 = DateTime(2025, 1, 1);
      final s = ChatSession(
        id: 'upd',
        title: 'upd',
        createdAt: t0,
        updatedAt: t0,
        messages: [
          ChatMessage(
            id: 'a',
            role: MessageRole.user,
            content: 'a',
            createdAt: t0,
          ),
        ],
      );
      await repo.save(s);

      final newMsgs = <ChatMessage>[
        ChatMessage(
          id: 'a',
          role: MessageRole.user,
          content: 'a',
          createdAt: t0,
        ),
        ChatMessage(
          id: 'b',
          role: MessageRole.assistant,
          content: 'b',
          createdAt: t0,
        ),
      ];
      await repo.updateMessages('upd', newMsgs);
      final loaded = repo.get('upd')!;
      expect(loaded.messages, hasLength(2));
      expect(loaded.messages[1].content, 'b');
      expect(loaded.updatedAt.isAfter(t0), isTrue);
    },
  );

  test('deriveTitle truncates long user messages', () {
    expect(ChatSession.deriveTitle('hi'), 'hi');
    final long = 'x' * 200;
    final t = ChatSession.deriveTitle(long);
    expect(t.length, lessThanOrEqualTo(41));
    expect(t.endsWith('…'), isTrue);
  });
}
