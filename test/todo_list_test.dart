import 'package:agent_buddy/models/todo_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TodoItem', () {
    test('toJson / fromJson round-trip preserves all fields', () {
      final original = TodoItem(
        id: 'td_abc',
        content: 'read the API docs',
        detail: 'use fetch_web + memory.search',
        order: 2,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
        completedAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_500_000),
      );
      final restored = TodoItem.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.content, original.content);
      expect(restored.detail, original.detail);
      expect(restored.order, original.order);
      expect(restored.status, original.status);
      expect(restored.createdAt, original.createdAt);
      expect(restored.completedAt, original.completedAt);
    });

    test('pending by default', () {
      final item = TodoItem(
        id: 'td_1',
        content: 'x',
        order: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(item.status, TodoItemStatus.pending);
      expect(item.isDone, isFalse);
      expect(item.completedAt, isNull);
    });

    test('copyWith marks completion and clears it', () {
      final item = TodoItem(
        id: 'td_1',
        content: 'x',
        order: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final done = item.copyWith(
        status: TodoItemStatus.done,
        completedAt: DateTime.fromMillisecondsSinceEpoch(1),
      );
      expect(done.isDone, isTrue);
      expect(done.completedAt, isNotNull);
      final cleared = done.copyWith(
        status: TodoItemStatus.pending,
        clearCompletedAt: true,
      );
      expect(cleared.isDone, isFalse);
      expect(cleared.completedAt, isNull);
    });

    test('copyWith(clearDetail: true) drops the detail string', () {
      final item = TodoItem(
        id: 'td_1',
        content: 'x',
        detail: 'old',
        order: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final updated = item.copyWith(clearDetail: true);
      expect(updated.detail, isNull);
    });

    test('toJson omits detail when null', () {
      final item = TodoItem(
        id: 'td_1',
        content: 'x',
        order: 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final json = item.toJson();
      expect(json.containsKey('detail'), isFalse);
    });

    test('wireName round-trip for both statuses', () {
      expect(TodoItemStatusX.fromWire('done'), TodoItemStatus.done);
      expect(TodoItemStatusX.fromWire('pending'), TodoItemStatus.pending);
      // Unknown wire strings fall back to pending (defensive).
      expect(TodoItemStatusX.fromWire(null), TodoItemStatus.pending);
      expect(TodoItemStatusX.fromWire('garbage'), TodoItemStatus.pending);
    });
  });

  group('TodoList', () {
    test('empty list has zero counts and allDone==true', () {
      const list = TodoList.empty;
      expect(list.isEmpty, isTrue);
      expect(list.isNotEmpty, isFalse);
      expect(list.totalCount, 0);
      expect(list.completedCount, 0);
      expect(list.allDone, isTrue);
      expect(list.pendingItems, isEmpty);
    });

    test('add + complete path computes counters correctly', () {
      var list = const TodoList();
      final t0 = DateTime.fromMillisecondsSinceEpoch(100);
      final t1 = DateTime.fromMillisecondsSinceEpoch(200);
      list = list.copyWith(
        createdAt: t0,
        items: [
          TodoItem(id: 'td_1', content: 'a', order: 0, createdAt: t0),
          TodoItem(id: 'td_2', content: 'b', order: 1, createdAt: t1),
        ],
      );
      expect(list.totalCount, 2);
      expect(list.completedCount, 0);
      expect(list.allDone, isFalse);

      final updated = list.items.first.copyWith(
        status: TodoItemStatus.done,
        completedAt: t1,
      );
      list = list.copyWith(items: [updated, list.items.last]);
      expect(list.completedCount, 1);
      expect(list.allDone, isFalse);
      expect(list.pendingItems.length, 1);
      expect(list.pendingItems.first.id, 'td_2');
    });

    test('toJson / fromJson round-trip preserves counters', () {
      final list = TodoList(
        title: '调研 OpenAI 缓存',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1234),
        revision: 7,
        items: [
          TodoItem(
            id: 'td_1',
            content: 'a',
            order: 0,
            createdAt: DateTime.fromMillisecondsSinceEpoch(1234),
            status: TodoItemStatus.done,
            completedAt: DateTime.fromMillisecondsSinceEpoch(1500),
          ),
          TodoItem(
            id: 'td_2',
            content: 'b',
            order: 1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(1300),
          ),
        ],
      );
      final restored = TodoList.fromJson(list.toJson());
      expect(restored.title, list.title);
      expect(restored.revision, list.revision);
      expect(restored.totalCount, list.totalCount);
      expect(restored.completedCount, list.completedCount);
      expect(restored.items.length, list.items.length);
      expect(restored.items[0].id, 'td_1');
      expect(restored.items[0].status, TodoItemStatus.done);
      expect(restored.items[1].id, 'td_2');
      expect(restored.items[1].status, TodoItemStatus.pending);
    });

    test('byId finds the right item or returns null', () {
      final list = TodoList(
        items: [
          TodoItem(
            id: 'td_1',
            content: 'a',
            order: 0,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
          TodoItem(
            id: 'td_2',
            content: 'b',
            order: 1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ],
      );
      expect(list.byId('td_2')?.content, 'b');
      expect(list.byId('nope'), isNull);
    });

    test('allDone returns true when all items are done', () {
      final items = [
        TodoItem(
          id: 'td_1',
          content: 'a',
          order: 0,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          status: TodoItemStatus.done,
          completedAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ];
      final list = TodoList(items: items);
      expect(list.allDone, isTrue);
      expect(list.pendingItems, isEmpty);
    });
  });
}
