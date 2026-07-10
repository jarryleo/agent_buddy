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

  /// Returns memories sorted newest-first by [Memory.createdAt].
  ///
  /// Filtering — **OR semantics** for every dimension:
  ///   - [keyword] (legacy single-string): a case-insensitive
  ///     `contains` on `content`. Kept for backward compat.
  ///   - [keywords] (preferred): same match, but a memory matches
  ///     if **any** keyword is contained in its `content` OR `tags`.
  ///     Empty / null list means "no keyword constraint".
  ///   - [tags] (preferred): a memory matches if **any** of its
  ///     tags is in this list (case-insensitive). Empty / null
  ///     means "no tag constraint".
  /// When both [keyword] and [keywords] are supplied, [keywords]
  /// wins; [keyword] is ignored. When no filter is supplied, the
  /// full store is returned (still capped at [max]).
  List<Memory> list({
    String? keyword,
    List<String>? keywords,
    List<String>? tags,
    int max = 50,
  }) {
    final kws =
        _normalizeList(keywords) ??
        (keyword == null ? const <String>[] : [keyword]);
    final tagFilter = _normalizeList(tags);

    final all = _box.values.toList();
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final hasKeyword = kws.isNotEmpty;
    final hasTag = tagFilter != null;
    if (!hasKeyword && !hasTag) {
      if (all.length <= max) return all;
      return all.sublist(0, max);
    }

    final filtered = all.where((m) {
      if (hasTag) {
        if (_tagsContainAny(m.tags, tagFilter)) return true;
      }
      if (hasKeyword && _contentOrTagsContainAny(m, kws)) return true;
      return false;
    }).toList();

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
    List<String> tags = const [],
    DateTime? createdAt,
  }) async {
    final now = createdAt ?? DateTime.now();
    final memory = Memory(
      id: 'm_${now.microsecondsSinceEpoch}_${_box.length}',
      content: content,
      source: source,
      createdAt: now,
      tags: _normalizeList(tags) ?? const <String>[],
    );
    await _box.put(memory.id, memory);
    return memory;
  }

  Future<Memory?> update({
    required String id,
    String? content,
    String? source,
    List<String>? tags,
  }) async {
    final existing = _box.get(id);
    if (existing == null) return null;
    final updated = existing.copyWith(
      content: content,
      source: source,
      tags: tags == null ? null : (_normalizeList(tags) ?? const <String>[]),
    );
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

/// Returns a lower-cased, trimmed, de-duplicated list, dropping
/// empty entries. Returns null if no entries survive.
List<String>? _normalizeList(Iterable<String>? raw) {
  if (raw == null) return null;
  final seen = <String>{};
  final out = <String>[];
  for (final s in raw) {
    final t = s.trim();
    if (t.isEmpty) continue;
    final k = t.toLowerCase();
    if (seen.add(k)) out.add(t);
  }
  return out.isEmpty ? null : out;
}

bool _tagsContainAny(List<String> memoryTags, List<String> filter) {
  if (memoryTags.isEmpty || filter.isEmpty) return false;
  final memoryLower = memoryTags.map((t) => t.toLowerCase()).toSet();
  for (final t in filter) {
    if (memoryLower.contains(t.toLowerCase())) return true;
  }
  return false;
}

bool _contentOrTagsContainAny(Memory m, List<String> kws) {
  if (kws.isEmpty) return false;
  final content = m.content.toLowerCase();
  for (final k in kws) {
    final lk = k.toLowerCase();
    if (content.contains(lk)) return true;
  }
  for (final tag in m.tags) {
    final t = tag.toLowerCase();
    for (final k in kws) {
      if (t.contains(k.toLowerCase())) return true;
    }
  }
  return false;
}
