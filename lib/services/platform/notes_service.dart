import 'package:hive_ce/hive.dart';

import '../../models/note.dart';

class NotesService {
  static const String boxName = 'notes';

  late final Box<Note> _box;
  bool _initialized = false;

  bool get isReady => _initialized;

  Future<void> open({Box<Note>? preopened}) async {
    if (_initialized) return;
    _box = preopened ?? await Hive.openBox<Note>(boxName);
    _initialized = true;
  }

  List<Note> list({String? keyword, int max = 50}) {
    final all = _box.values.toList();
    all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final lower = keyword?.toLowerCase();
    final filtered = (lower == null || lower.isEmpty)
        ? all
        : all
              .where(
                (n) =>
                    n.title.toLowerCase().contains(lower) ||
                    n.content.toLowerCase().contains(lower),
              )
              .toList();
    if (filtered.length <= max) return filtered;
    return filtered.sublist(0, max);
  }

  Note? get(String id) {
    if (id.isEmpty) return null;
    return _box.get(id);
  }

  Future<Note> create({required String title, required String content}) async {
    final now = DateTime.now();
    final note = Note(
      id: 'n_${now.microsecondsSinceEpoch}_${_box.length}',
      title: title,
      content: content,
      createdAt: now,
      updatedAt: now,
    );
    await _box.put(note.id, note);
    return note;
  }

  Future<Note?> update({
    required String id,
    String? title,
    String? content,
  }) async {
    final existing = _box.get(id);
    if (existing == null) return null;
    final updated = existing.copyWith(
      title: title,
      content: content,
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
