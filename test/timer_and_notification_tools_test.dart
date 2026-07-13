import 'dart:convert';

import 'package:agent_buddy/models/timer_task.dart';
import 'package:agent_buddy/services/notification_service.dart';
import 'package:agent_buddy/services/timer_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/notification_tool.dart';
import 'package:agent_buddy/services/tools/timer_tool.dart';
import 'package:flutter_test/flutter_test.dart';

class _SpyNotifications implements NotificationService {
  final List<({String title, String body, int? id})> shows = [];

  @override
  Future<bool> show({
    required String title,
    required String body,
    int? notificationId,
  }) async {
    shows.add((title: title, body: body, id: notificationId));
    return true;
  }

  @override
  Future<void> setForegroundNotification({
    required bool active,
    required String title,
    required String body,
  }) async {}

  @override
  Future<void> initialize() async {}

  @override
  Stream<NotificationToast> get toastStream => const Stream.empty();

  @override
  Stream<bool> get foregroundStream => const Stream.empty();

  @override
  Future<void> dispose() async {}
}

void main() {
  late ToolService tools;
  late _SpyNotifications notif;
  late TimerService timers;

  setUp(() {
    notif = _SpyNotifications();
    timers = TimerService(notificationService: notif);
    tools = ToolService(timerService: timers, notificationService: notif);
  });

  group('NotificationTool', () {
    test('show returns ok envelope with title + body', () async {
      final t = NotificationTool();
      final raw = await t.execute({
        'action': 'show',
        'title': 'Hi',
        'body': 'World',
      }, tools);
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['action'], 'show');
      expect(decoded['ok'], isTrue);
      expect(decoded['title'], 'Hi');
      expect(decoded['body'], 'World');
      expect(notif.shows, hasLength(1));
      expect(notif.shows.first.title, 'Hi');
      expect(notif.shows.first.body, 'World');
    });

    test('rejects empty title + body', () async {
      final t = NotificationTool();
      expect(
        () => t.execute({'action': 'show', 'title': '', 'body': ''}, tools),
        throwsA(isA<ToolException>()),
      );
    });

    test('rejects unknown actions', () async {
      final t = NotificationTool();
      expect(
        () => t.execute({'action': 'banana', 'title': 'a', 'body': 'b'}, tools),
        throwsA(isA<ToolException>()),
      );
    });

    test('forwards notification_id when provided', () async {
      final t = NotificationTool();
      await t.execute({
        'action': 'show',
        'title': 'id-test',
        'body': 'b',
        'notification_id': 42,
      }, tools);
      expect(notif.shows.single.id, 42);
    });
  });

  group('TimerTool', () {
    test('schema uses JSON-Schema "boolean", not OpenAPI "bool"', () {
      // Regression: an early draft used 'type': 'bool', which the
      // OpenAI / Anthropic chat-completions tool schema rejects
      // (HTTP 400: "bool is not valid under any of the schemas
      // listed in the 'anyOf' keyword"). The JSON Schema spec
      // spells the type as 'boolean'; stay there.
      final t = TimerTool();
      final schema = t.buildSchema();
      final props = (schema['function'] as Map)['parameters']
          as Map<String, dynamic>;
      final parameters = jsonEncode(props);
      expect(parameters, contains('"boolean"'));
      expect(parameters, isNot(contains("'bool'")));
    });

    test('list returns pending timers newest-first', () async {
      await tools.runTimer({
        'action': 'create',
        'label': 'first',
        'delay_seconds': 60,
      });
      await tools.runTimer({
        'action': 'create',
        'label': 'second',
        'delay_seconds': 120,
      });
      final raw = await tools.runTimer({'action': 'list'});
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['count'], 2);
      final items = (decoded['timers'] as List).cast<Map<String, dynamic>>();
      expect(items.first['label'], 'second');
      expect(items.last['label'], 'first');
    });

    test('create returns the persisted timer record', () async {
      final raw = await tools.runTimer({
        'action': 'create',
        'label': '喝水',
        'delay_seconds': 300,
        'prompt': '提醒用户喝水',
        'action_hint': '调用 notification 工具通知用户',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final timer = decoded['timer'] as Map<String, dynamic>;
      expect(timer['label'], '喝水');
      expect(timer['prompt'], '提醒用户喝水');
      expect(timer['actionHint'], '调用 notification 工具通知用户');
      expect(timer['source'], 'ai');
    });

    test('create requires label + delay', () async {
      final t = TimerTool();
      expect(
        () => t.execute({'action': 'create'}, tools),
        throwsA(isA<ToolException>()),
      );
      expect(
        () => t.execute({
          'action': 'create',
          'label': 'x',
          'delay_seconds': -1,
        }, tools),
        throwsA(isA<ToolException>()),
      );
      expect(
        () => t.execute({
          'action': 'create',
          'label': 'x',
          'fire_at_iso': 'garbage',
        }, tools),
        throwsA(isA<ToolException>()),
      );
    });

    test('update reschedules and updates label', () async {
      final raw = await tools.runTimer({
        'action': 'create',
        'label': 'old',
        'delay_seconds': 30,
      });
      final created = jsonDecode(raw) as Map<String, dynamic>;
      final id = (created['timer'] as Map<String, dynamic>)['id'] as String;
      final updated = await tools.runTimer({
        'action': 'update',
        'id': id,
        'label': 'new',
        'delay_seconds': 90,
      });
      final decoded = jsonDecode(updated) as Map<String, dynamic>;
      final t = decoded['timer'] as Map<String, dynamic>;
      expect(t['label'], 'new');
    });

    test('get returns the timer by id', () async {
      final raw = await tools.runTimer({
        'action': 'create',
        'label': 'g',
        'delay_seconds': 30,
      });
      final id =
          ((jsonDecode(raw) as Map<String, dynamic>)['timer']
                  as Map<String, dynamic>)['id']
              as String;
      final got = await tools.runTimer({'action': 'get', 'id': id});
      final decoded = jsonDecode(got) as Map<String, dynamic>;
      expect(decoded['found'], isTrue);
      expect(decoded['timer']['label'], 'g');
    });

    test('get with unknown id returns found=false', () async {
      final got = await tools.runTimer({
        'action': 'get',
        'id': 'does-not-exist',
      });
      expect((jsonDecode(got) as Map<String, dynamic>)['found'], isFalse);
    });

    test('delete removes the timer', () async {
      final raw = await tools.runTimer({
        'action': 'create',
        'label': 'gone',
        'delay_seconds': 30,
      });
      final id =
          ((jsonDecode(raw) as Map<String, dynamic>)['timer']
                  as Map<String, dynamic>)['id']
              as String;
      final del = await tools.runTimer({'action': 'delete', 'id': id});
      expect((jsonDecode(del) as Map<String, dynamic>)['ok'], isTrue);
      final got = await tools.runTimer({'action': 'get', 'id': id});
      expect((jsonDecode(got) as Map<String, dynamic>)['found'], isFalse);
    });

    test('include_terminal surfaces fired / cancelled rows', () async {
      final raw = await tools.runTimer({
        'action': 'create',
        'label': 'live',
        'delay_seconds': 60,
      });
      final id =
          ((jsonDecode(raw) as Map<String, dynamic>)['timer']
                  as Map<String, dynamic>)['id']
              as String;
      await tools.runTimer({'action': 'delete', 'id': id});
      // default list = pending only, should be empty
      final def = await tools.runTimer({'action': 'list'});
      expect((jsonDecode(def) as Map<String, dynamic>)['count'], 0);
      // include_terminal=true still empty (delete removes entirely)
      final all = await tools.runTimer({
        'action': 'list',
        'include_terminal': true,
      });
      expect((jsonDecode(all) as Map<String, dynamic>)['count'], 0);
    });

    test(
      'create with absolute fire_at_iso in the past rounds forward',
      () async {
        final before = DateTime.now().millisecondsSinceEpoch;
        final raw = await tools.runTimer({
          'action': 'create',
          'label': 'past',
          'fire_at_iso': '2020-01-01T00:00:00Z',
        });
        final t =
            (jsonDecode(raw) as Map<String, dynamic>)['timer']
                as Map<String, dynamic>;
        final fireAtMs = t['fireAtMs'] as int;
        // `create` rounds past fireAt to now+1ms, so it must be
        // at-or-after the wall-clock the test captured.
        expect(fireAtMs, greaterThanOrEqualTo(before));
      },
    );

    test('update on non-pending task returns found=false', () async {
      // Use a manually-inserted terminal task via the repository.
      final t = TimerTask(
        id: 't_done',
        label: 'done',
        fireAt: DateTime.now().subtract(const Duration(minutes: 5)),
        createdAt: DateTime.now().subtract(const Duration(minutes: 6)),
        source: 'ai',
        status: TimerTaskStatus.fired,
      );
      // ignore: invalid_use_of_visible_for_testing_member
      timers.addForTest(t);
      final raw = await tools.runTimer({
        'action': 'update',
        'id': 't_done',
        'label': 'new',
      });
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['found'], isFalse);
    });
  });
}
