import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/timer_task.dart';
import 'notification_service.dart';

/// In-memory timer queue + scheduler. Owns the [Timer]s that fire
/// AI-set reminders. Notifies its listeners on add / update / delete
/// / fire so the settings tab and the foreground notification can
/// stay in sync without a full Hive round-trip.
///
/// The service is **only effective while the app is running** — no
/// persistence to disk, no native background workers. The whole
/// queue is lost on app kill. This is intentional: a system
/// notification surfaced from a dead process is confusing, and the
/// user can always re-create the timer.
class TimerService extends ChangeNotifier {
  TimerService({NotificationService? notificationService})
    : _notifications = notificationService ?? NotificationService.instance;

  final NotificationService _notifications;

  /// All known tasks, in insertion order. Pending tasks are also
  /// scheduled via [Timer]s; terminal tasks (fired / cancelled)
  /// stay in the list briefly so the UI can show a history, but
  /// they're pruned out of the scheduling map and the foreground
  /// notification's count.
  final List<TimerTask> _tasks = [];

  /// id → active [Timer] handle. We hold the handle so updates
  /// and deletes can cancel the in-flight task before re-scheduling
  /// / removing.
  final Map<String, Timer> _scheduled = {};

  /// Optional callback fired whenever a pending task transitions
  /// to `fired`. ChatProvider wires this up to spawn a new chat
  /// turn that drives the `notification` tool.
  void Function(TimerTask task)? onTimerFired;

  /// Read-only snapshot. Newest-first so the settings tab shows
  /// the most recent task on top.
  List<TimerTask> get tasks {
    final copy = List<TimerTask>.from(_tasks);
    copy.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(copy);
  }

  /// Pending-only snapshot. Used by the foreground notification
  /// to compute its body text.
  List<TimerTask> get pending {
    return List.unmodifiable(
      _tasks.where((t) => t.status == TimerTaskStatus.pending).toList(),
    );
  }

  int get pendingCount =>
      _tasks.where((t) => t.status == TimerTaskStatus.pending).length;

  TimerTask? getById(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Test hook: injects a task directly into the queue without
  /// scheduling a [Timer]. Used to set up non-pending rows in
  /// unit tests; do not call from production code.
  @visibleForTesting
  void addForTest(TimerTask task) {
    _tasks.add(task);
    notifyListeners();
  }

  /// Creates a new timer and schedules it. The caller can pass
  /// either [fireAt] (an absolute wall-clock instant) or
  /// [delay] (a relative duration). [fireAt] wins if both are set.
  /// [delay] must be non-negative; [fireAt] must be in the future
  /// (rounded to the next millisecond if it's already past).
  ///
  /// The returned [TimerTask] is the persisted record (the id is
  /// the public, stable handle for `get` / `update` / `delete`).
  Future<TimerTask> create({
    required String label,
    DateTime? fireAt,
    Duration? delay,
    String prompt = '',
    String? actionHint,
    String source = 'ai',
  }) async {
    if (label.trim().isEmpty) {
      throw ArgumentError.value(label, 'label', 'must not be empty');
    }
    final now = DateTime.now();
    DateTime resolvedFireAt;
    if (fireAt != null) {
      resolvedFireAt = fireAt.isAfter(now)
          ? fireAt
          : now.add(const Duration(milliseconds: 1));
    } else if (delay != null) {
      final d = delay.isNegative ? Duration.zero : delay;
      resolvedFireAt = now.add(d);
    } else {
      throw ArgumentError('either fireAt or delay is required');
    }
    final id = _mintId();
    final task = TimerTask(
      id: id,
      label: label.trim(),
      fireAt: resolvedFireAt,
      createdAt: now,
      source: source,
      prompt: prompt,
      actionHint: actionHint,
    );
    _tasks.add(task);
    _scheduleTask(task);
    await _refreshForegroundNotification();
    notifyListeners();
    return task;
  }

  /// Updates an existing task. Only pending tasks are mutable;
  /// once a task has fired or been cancelled we reject the call
  /// so the model can't accidentally "resurrect" a finished timer.
  /// Pass any of [label] / [fireAt] / [delay] / [prompt] /
  /// [actionHint] to override; null = leave alone. If both
  /// [fireAt] and [delay] are provided, [fireAt] wins.
  Future<TimerTask?> update({
    required String id,
    String? label,
    DateTime? fireAt,
    Duration? delay,
    String? prompt,
    String? actionHint,
  }) async {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx < 0) return null;
    final existing = _tasks[idx];
    if (!existing.isPending) return null;

    final now = DateTime.now();
    DateTime? newFireAt;
    if (fireAt != null) {
      newFireAt = fireAt.isAfter(now)
          ? fireAt
          : now.add(const Duration(milliseconds: 1));
    } else if (delay != null) {
      final d = delay.isNegative ? Duration.zero : delay;
      newFireAt = now.add(d);
    }
    final updated = existing.copyWith(
      label: label?.trim(),
      fireAt: newFireAt,
      prompt: prompt,
      actionHint: actionHint,
    );
    _tasks[idx] = updated;
    // Reschedule. The schedule map entry is keyed by id so it's
    // safe to overwrite — we always cancel the previous handle
    // before re-scheduling.
    final prev = _scheduled.remove(id);
    prev?.cancel();
    if (updated.isPending) _scheduleTask(updated);
    await _refreshForegroundNotification();
    notifyListeners();
    return updated;
  }

  /// Cancels a pending task. The task is kept in the list with
  /// status=`cancelled` so the UI can show a "cancelled" history
  /// entry briefly, then prunes it out.
  Future<bool> cancel(String id) async {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx < 0) return false;
    final existing = _tasks[idx];
    if (!existing.isPending) return false;
    _tasks[idx] = existing.copyWith(status: TimerTaskStatus.cancelled);
    final t = _scheduled.remove(id);
    t?.cancel();
    await _refreshForegroundNotification();
    notifyListeners();
    return true;
  }

  /// Hard-removes a task from the list. Used by the settings
  /// tab's "delete" affordance and by the model's `delete`
  /// action. Returns true if anything was removed.
  Future<bool> delete(String id) async {
    final removed = _tasks.indexWhere((t) => t.id == id);
    if (removed < 0) return false;
    _tasks.removeAt(removed);
    final t = _scheduled.remove(id);
    t?.cancel();
    await _refreshForegroundNotification();
    notifyListeners();
    return true;
  }

  /// Prunes terminal tasks that have already been shown to the
  /// user. Called opportunistically after a fire / cancel so the
  /// list doesn't grow without bound across a long session.
  void pruneTerminal() {
    final before = _tasks.length;
    _tasks.removeWhere((t) => t.isTerminal);
    if (_tasks.length != before) notifyListeners();
  }

  void _scheduleTask(TimerTask task) {
    final delay = task.delay;
    if (delay <= Duration.zero) {
      // Already in the past — fire on the next microtask so the
      // caller's `create` future completes first.
      scheduleMicrotask(() => _fire(task.id));
      return;
    }
    final timer = Timer(delay, () => _fire(task.id));
    _scheduled[task.id] = timer;
  }

  void _fire(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final task = _tasks[idx];
    if (!task.isPending) return;
    _tasks[idx] = task.copyWith(status: TimerTaskStatus.fired);
    _scheduled.remove(id);

    // Best-effort: surface an OS notification right now so the
    // user sees *something* even if the AI turn is slow. The AI
    // will normally follow up with its own `notification` call
    // using the timer prompt; the in-app overlay / system
    // notification is the safety net.
    _notifications.show(
      title: task.label,
      body: task.prompt.isNotEmpty ? task.prompt : 'Timer fired',
    );

    // Schedule the chat turn. We don't await this — the chat
    // turn is async and may be ignored if the app is shutting
    // down. onTimerFired is responsible for any state cleanup
    // (e.g. waiting for the user to be ready before sending).
    onTimerFired?.call(_tasks[idx]);

    // Refresh the foreground notification (count decreased by 1)
    // and prune this entry after a short delay so the user has a
    // moment to see "fired" in the UI.
    _refreshForegroundNotification();
    notifyListeners();
    Timer(const Duration(seconds: 30), () {
      pruneTerminal();
    });
  }

  String _mintId() {
    // Microsecond timestamp + tasks length. Avoids the cost of
    // Uuid for the hot path; the length suffix makes collisions
    // impossible even when the same µs is hit on a fast device.
    return 't_${DateTime.now().microsecondsSinceEpoch}_${_tasks.length}';
  }

  Future<void> _refreshForegroundNotification() async {
    final count = pendingCount;
    if (count == 0) {
      await _notifications.setForegroundNotification(
        active: false,
        title: '',
        body: '',
      );
      return;
    }
    final first = _tasks.firstWhere(
      (t) => t.isPending,
      orElse: () => _tasks.first,
    );
    final title = count == 1
        ? '1 active timer: ${first.label}'
        : '$count active timers';
    final body = first.label;
    await _notifications.setForegroundNotification(
      active: true,
      title: title,
      body: body,
    );
  }

  @override
  void dispose() {
    for (final t in _scheduled.values) {
      t.cancel();
    }
    _scheduled.clear();
    super.dispose();
  }
}
