import 'package:agent_buddy/models/timer_task.dart';
import 'package:agent_buddy/services/notification_service.dart';
import 'package:agent_buddy/services/timer_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures every toast the [NotificationService] emits and
/// every fire callback the [TimerService] raises. Used by the
/// tests below to assert side-effects without standing up the
/// real plugin / overlay.
class _SpyNotifications implements NotificationService {
  final List<({String title, String body})> shows = [];
  final List<bool> foregroundStates = [];

  @override
  Future<bool> show({
    required String title,
    required String body,
    int? notificationId,
  }) async {
    shows.add((title: title, body: body));
    return true;
  }

  @override
  Future<void> setForegroundNotification({
    required bool active,
    required String title,
    required String body,
  }) async {
    foregroundStates.add(active);
  }

  // Stubs for the rest of the API. Tests don't read these, but
  // the `implements` clause forces us to provide them.
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
  group('TimerTask model', () {
    test('round-trips through JSON', () {
      final t = TimerTask(
        id: 't_1',
        label: 'drink water',
        fireAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
        createdAt: DateTime.fromMillisecondsSinceEpoch(1_699_999_000_000),
        source: 'ai',
        prompt: 'remind the user',
        actionHint: 'call notification',
      );
      final round = TimerTask.fromJson(t.toJson());
      expect(round.id, t.id);
      expect(round.label, t.label);
      expect(round.fireAt, t.fireAt);
      expect(round.createdAt, t.createdAt);
      expect(round.source, t.source);
      expect(round.prompt, t.prompt);
      expect(round.actionHint, t.actionHint);
      expect(round.status, TimerTaskStatus.pending);
    });

    test('reads v1 records (no actionHint) without throwing', () {
      final t = TimerTask.fromJson({
        'id': 't_legacy',
        'label': 'old',
        'fireAtMs': 1700000000000,
        'createdAtMs': 1699999000000,
        'source': 'user',
        'prompt': '',
        'status': 'pending',
      });
      expect(t.actionHint, isNull);
      expect(t.label, 'old');
    });

    test('delay is negative when fireAt is in the past', () {
      final t = TimerTask(
        id: 't',
        label: 'past',
        fireAt: DateTime.now().subtract(const Duration(minutes: 5)),
        createdAt: DateTime.now(),
        source: 'ai',
      );
      expect(t.delay.isNegative, isTrue);
    });
  });

  group('TimerService CRUD + scheduling', () {
    test('create schedules a Dart timer that fires the callback', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      final fired = <TimerTask>[];
      svc.onTimerFired = fired.add;
      final t = await svc.create(
        label: 'wake up',
        delay: const Duration(milliseconds: 50),
        prompt: 'wake up',
      );
      expect(t.isPending, isTrue);
      expect(svc.pendingCount, 1);
      // Wait for the timer to fire.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(fired.length, 1);
      expect(fired.first.id, t.id);
      expect(fired.first.label, 'wake up');
      expect(notif.shows, hasLength(1));
      expect(notif.shows.first.title, 'wake up');
      expect(notif.shows.first.body, 'wake up');
      // After fire, the task flips to terminal and the foreground
      // notification is turned off.
      expect(svc.pendingCount, 0);
      expect(notif.foregroundStates.last, isFalse);
    });

    test('update reschedules a pending task', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      final fired = <TimerTask>[];
      svc.onTimerFired = fired.add;
      final t = await svc.create(
        label: 'first',
        delay: const Duration(seconds: 30),
      );
      final updated = await svc.update(
        id: t.id,
        label: 'renamed',
        delay: const Duration(milliseconds: 50),
      );
      expect(updated, isNotNull);
      expect(updated!.label, 'renamed');
      expect(svc.tasks.first.label, 'renamed');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(fired.length, 1);
      expect(fired.first.label, 'renamed');
    });

    test('update rejects terminal tasks', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      final t = await svc.create(
        label: 'a',
        delay: const Duration(milliseconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      // Fetch the *current* record (t is the original pending copy).
      final current = svc.getById(t.id);
      expect(current, isNotNull);
      expect(current!.isPending, isFalse);
      final updated = await svc.update(id: t.id, label: 'cannot');
      expect(updated, isNull);
    });

    test('cancel keeps a cancelled record in the list', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      final fired = <TimerTask>[];
      svc.onTimerFired = fired.add;
      final t = await svc.create(label: 'c', delay: const Duration(seconds: 5));
      final ok = await svc.cancel(t.id);
      expect(ok, isTrue);
      expect(svc.tasks.first.isCancelled, isTrue);
      // Cancel doesn't fire.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fired, isEmpty);
    });

    test('delete removes the task entirely', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      final t = await svc.create(
        label: 'gone',
        delay: const Duration(seconds: 5),
      );
      final ok = await svc.delete(t.id);
      expect(ok, isTrue);
      expect(svc.tasks, isEmpty);
      expect(svc.pendingCount, 0);
    });

    test('create rounds past fireAt to ~1ms in the future', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      final t = await svc.create(
        label: 'past',
        fireAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(t.fireAt.isAfter(DateTime.now()), isTrue);
    });

    test('fire triggers foreground notification refresh on create', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      await svc.create(label: 'a', delay: const Duration(seconds: 30));
      await svc.create(label: 'b', delay: const Duration(seconds: 60));
      // First foreground update (active=true with 2 timers), then
      // more on subsequent creates.
      expect(notif.foregroundStates, contains(true));
      expect(notif.foregroundStates.last, isTrue);
      await svc.delete(svc.tasks.first.id);
      expect(notif.foregroundStates.last, isTrue);
      await svc.delete(svc.tasks.first.id);
      expect(notif.foregroundStates.last, isFalse);
    });

    test('pruneTerminal removes fired / cancelled rows', () async {
      final notif = _SpyNotifications();
      final svc = TimerService(notificationService: notif);
      svc.onTimerFired = (_) {};
      // 'a' is pending (long delay); 'b' will fire quickly.
      await svc.create(label: 'a', delay: const Duration(seconds: 60));
      await svc.create(label: 'b', delay: const Duration(milliseconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // Now 'a' is still pending, 'b' has fired.
      expect(svc.tasks.length, 2);
      expect(svc.tasks.where((t) => t.isFired), hasLength(1));
      // The fire callback delays pruning by 30s; force it now.
      svc.pruneTerminal();
      expect(svc.tasks.length, 1);
      expect(svc.tasks.first.label, 'a');
      expect(svc.tasks.first.isPending, isTrue);
    });
  });
}
