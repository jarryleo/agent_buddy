import 'package:hive_ce/hive.dart';

import '../../models/task.dart';

class TasksService {
  static const String boxName = 'tasks';

  late final Box<Task> _box;
  bool _initialized = false;

  bool get isReady => _initialized;

  Future<void> open({Box<Task>? preopened}) async {
    if (_initialized) return;
    _box = preopened ?? await Hive.openBox<Task>(boxName);
    _initialized = true;
  }

  List<Task> list({bool includeCompleted = false, int max = 50}) {
    final all = _box.values.toList();
    final filtered = includeCompleted
        ? all
        : all.where((t) => !t.completed).toList();
    filtered.sort((a, b) {
      final aDue = a.due?.millisecondsSinceEpoch ?? 0;
      final bDue = b.due?.millisecondsSinceEpoch ?? 0;
      if (aDue == 0 && bDue == 0) {
        return b.createdAt.compareTo(a.createdAt);
      }
      if (aDue == 0) return 1;
      if (bDue == 0) return -1;
      return aDue.compareTo(bDue);
    });
    if (filtered.length <= max) return filtered;
    return filtered.sublist(0, max);
  }

  Task? get(String id) {
    if (id.isEmpty) return null;
    return _box.get(id);
  }

  Future<Task> create({
    required String title,
    String? notes,
    DateTime? due,
  }) async {
    final now = DateTime.now();
    final task = Task(
      id: 't_${now.microsecondsSinceEpoch}_${_box.length}',
      title: title,
      notes: notes,
      due: due,
      completed: false,
      createdAt: now,
      updatedAt: now,
    );
    await _box.put(task.id, task);
    return task;
  }

  Future<Task?> complete(String id) async {
    final existing = _box.get(id);
    if (existing == null) return null;
    final now = DateTime.now();
    final updated = existing.copyWith(
      completed: true,
      completedAt: now,
      updatedAt: now,
    );
    await _box.put(id, updated);
    return updated;
  }

  Future<Task?> update({
    required String id,
    String? title,
    String? notes,
    DateTime? due,
  }) async {
    final existing = _box.get(id);
    if (existing == null) return null;
    final updated = existing.copyWith(
      title: title,
      notes: notes,
      due: due,
      updatedAt: DateTime.now(),
    );
    await _box.put(id, updated);
    return updated;
  }

  Future<bool> delete(String id) async {
    if (!_box.containsKey(id)) return false;
    await _box.delete(id);
    return true;
  }

  Future<void> close() async {
    if (!_initialized) return;
    await _box.close();
    _initialized = false;
  }
}
