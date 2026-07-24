import 'dart:io';

import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/download_service.dart';
import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Integration tests for the per-conversation task list and
/// the auto-supervision loop. The tests build a real
/// [ChatProvider] against an in-memory SharedPreferences and a
/// temp Hive directory so the persistence path is exercised
/// end-to-end. The streaming API surface is replaced with a
/// no-op fake so we can drive the provider's state machine
/// without burning tokens.
void main() {
  late Directory tempDir;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_todo_it_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<ChatProvider> buildProvider(StorageService storage) async {
    final settings = SettingsProvider(storage);
    await settings.load();

    // Register a cloud provider so the cloud path is wired up
    // even though we'll never actually invoke it — we drive the
    // todo list directly via the public dispatcher.
    final created = await settings.addProvider(
      name: 'Test',
      protocol: ProviderProtocol.openai,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      chatPath: '/chat/completions',
    );
    final withModel = created.copyWith(
      models: ['gpt-test'],
      selectedModel: 'gpt-test',
    );
    await settings.updateProvider(withModel);
    await settings.setActiveProvider(withModel.id);
    await settings.setUseLocalModel(false);

    final api = ApiService();
    final tools = ToolService(storage: storage);
    return ChatProvider(
      storage,
      api,
      tools,
      ImageService(),
      LocalLlmService(),
      settings,
      DownloadService(),
      FileAttachmentService(),
    );
  }

  /// Drives [ChatProvider._onTodoToolCall] directly with the
  /// todo-tool call shape the model would emit, so the test
  /// can assert on the resulting [ChatProvider.todoList]
  /// without going through the streaming pipeline.
  Future<String> invokeTodo(ChatProvider chat, Map<String, dynamic> args) {
    final fakeToolCall = {
      'id': 'tc_${DateTime.now().microsecondsSinceEpoch}',
      'name': 'todo',
      'arguments': args,
    };
    final ctx = _NoopBuildContext();
    return chat.debugOnTodoToolCall(
      context: ctx,
      toolCall: fakeToolCall,
      assistantId: 'a1',
      args: args,
    );
  }

  group('todo list mutations', () {
    test('add → list shows the item, pendingCount = 1', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      expect(chat.todoList.isEmpty, isTrue);

      final result = await invokeTodo(chat, {
        'action': 'add',
        'content': 'first step',
        'detail': 'do this with fetch_web',
      });

      expect(chat.todoList.items.length, 1);
      expect(chat.todoList.items.first.content, 'first step');
      expect(chat.todoList.items.first.detail, 'do this with fetch_web');
      expect(chat.todoList.items.first.isDone, isFalse);
      expect(chat.hasPendingTodos, isTrue);
      expect(result, contains('"ok":true'));

      // The session was persisted, so a reload restores the
      // item too.
      final reloaded = storage.sessions.get(chat.activeSessionId)!;
      expect(reloaded.todoList.items.length, 1);
    });

    test('complete marks the item done and updates counters', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      await invokeTodo(chat, {'action': 'add', 'content': 'b'});
      final idA = chat.todoList.items[0].id;

      await invokeTodo(chat, {'action': 'complete', 'id': idA});
      expect(chat.todoList.completedCount, 1);
      expect(chat.todoList.pendingItems.length, 1);
      expect(chat.todoList.allDone, isFalse);
      expect(chat.hasPendingTodos, isTrue);
    });

    test('clear drops the list and resets state', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      await invokeTodo(chat, {'action': 'add', 'content': 'b'});
      expect(chat.todoList.items.length, 2);

      await invokeTodo(chat, {'action': 'clear'});
      expect(chat.todoList.isEmpty, isTrue);
      expect(chat.hasPendingTodos, isFalse);
      expect(chat.userStoppedLastTurn, isFalse);
    });

    test(
      'add on empty list auto-creates a list (model forgot create)',
      () async {
        final storage = StorageService();
        await storage.init();
        final chat = await buildProvider(storage);

        await invokeTodo(chat, {'action': 'add', 'content': 'orphan step'});
        expect(chat.todoList.items.length, 1);
        expect(chat.todoList.items.first.content, 'orphan step');
      },
    );

    test('unknown id on complete returns a soft error envelope', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      final result = await invokeTodo(chat, {
        'action': 'complete',
        'id': 'td_does_not_exist',
      });
      expect(result, contains('"ok":false'));
      expect(result, contains('no such todo item'));
    });

    test('update rewrites content and detail', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {
        'action': 'add',
        'content': 'old',
        'detail': 'd',
      });
      final id = chat.todoList.items.first.id;

      await invokeTodo(chat, {
        'action': 'update',
        'id': id,
        'content': 'new',
        'detail': '',
      });
      expect(chat.todoList.items.first.content, 'new');
      // Empty detail string is normalized to null so the panel
      // doesn't render an empty caption row.
      expect(chat.todoList.items.first.detail, isNull);
    });

    test('remove drops the item by id', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      await invokeTodo(chat, {'action': 'add', 'content': 'b'});
      final firstId = chat.todoList.items.first.id;

      await invokeTodo(chat, {'action': 'remove', 'id': firstId});
      expect(chat.todoList.items.length, 1);
      expect(chat.todoList.items.first.content, 'b');
    });

    test('list envelope mirrors the in-memory shape', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      final result = await invokeTodo(chat, {'action': 'list'});
      expect(result, contains('"action":"list"'));
      expect(result, contains('"count":1'));
      expect(result, contains('"total":1'));
      expect(result, contains('"completed":0'));
    });

    test('revision counter bumps on every mutation', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      final r0 = chat.todoList.revision;
      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      final r1 = chat.todoList.revision;
      await invokeTodo(chat, {'action': 'add', 'content': 'b'});
      final r2 = chat.todoList.revision;
      expect(r1, greaterThan(r0));
      expect(r2, greaterThan(r1));
    });
  });

  group('supervision state machine', () {
    test('abandonTodoList drops the list and clears the stop flag', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      await invokeTodo(chat, {'action': 'add', 'content': 'b'});
      chat.debugSetUserStoppedLastTurn(true);

      await chat.abandonTodoList();
      expect(chat.todoList.isEmpty, isTrue);
      expect(chat.userStoppedLastTurn, isFalse);
    });

    test('a fresh sendMessage clears _userStoppedLastTurn', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      chat.debugSetUserStoppedLastTurn(true);
      expect(chat.userStoppedLastTurn, isTrue);

      chat.debugClearUserStoppedOnSend();
      expect(chat.userStoppedLastTurn, isFalse);
    });

    test('selecting a different session drops supervision state', () async {
      final storage = StorageService();
      await storage.init();
      final chat = await buildProvider(storage);

      await invokeTodo(chat, {'action': 'add', 'content': 'a'});
      expect(chat.todoList.items.length, 1);

      chat.debugSetUserStoppedLastTurn(true);

      await chat.createNewSession();
      expect(chat.todoList.isEmpty, isTrue);
      expect(chat.userStoppedLastTurn, isFalse);
    });
  });
}

/// Minimal [BuildContext] for [ChatProvider._onTodoToolCall]
/// (which never reaches into the widget tree, so an empty
/// Element / BuildOwner suffices). For production the
/// dispatcher is reached via the orchestrator with a real
/// [BuildContext] from the message bubble; tests use this
/// stub because the only context-dependent code paths in
/// `_onTodoToolCall` are no-ops (notifications, save
/// snackbars, etc. all live in different methods).
class _NoopBuildContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
