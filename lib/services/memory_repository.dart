import 'package:hive_ce/hive.dart';

import '../models/memory.dart';
import '../models/memory_adapter.dart';

class MemoryRepository {
  static const String boxName = 'memories';
  static const int _typeId = 4;

  late final Box<Memory> _box;
  bool _initialized = false;

  bool get isReady => _initialized;

  static void registerAdapters() {
    if (!Hive.isAdapterRegistered(_typeId)) {
      Hive.registerAdapter(MemoryAdapter());
    }
  }

  Future<void> open({Box<Memory>? preopened}) async {
    if (_initialized) return;
    registerAdapters();
    _box = preopened ?? await Hive.openBox<Memory>(boxName);
    _initialized = true;
  }

  List<Memory> list({String? keyword, int max = 50}) {
    final all = _box.values.toList();
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final lower = keyword?.toLowerCase();
    final filtered = (lower == null || lower.isEmpty)
        ? all
        : all.where((m) => m.content.toLowerCase().contains(lower)).toList();
    if (filtered.length <= max) return filtered;
    return filtered.sublist(0, max);
  }

  Memory? get(String id) {
    if (id.isEmpty) return null;
    return _box.get(id);
  }

  Future<Memory> add({
    required String content,
    required String source,
    DateTime? createdAt,
  }) async {
    final now = createdAt ?? DateTime.now();
    final memory = Memory(
      id: 'm_${now.microsecondsSinceEpoch}_${_box.length}',
      content: content,
      source: source,
      createdAt: now,
    );
    await _box.put(memory.id, memory);
    return memory;
  }

  Future<Memory?> update({
    required String id,
    String? content,
    String? source,
  }) async {
    final existing = _box.get(id);
    if (existing == null) return null;
    final updated = existing.copyWith(content: content, source: source);
    await _box.put(id, updated);
    return updated;
  }

  Future<bool> delete(String id) async {
    if (!_box.containsKey(id)) return false;
    await _box.delete(id);
    return true;
  }

  Future<void> deleteMany(Iterable<String> ids) async {
    for (final id in ids) {
      try {
        await _box.delete(id);
      } catch (_) {}
    }
  }

  int get length => _box.length;

  Future<void> close() async {
    if (!_initialized) return;
    await _box.close();
    _initialized = false;
  }
}
