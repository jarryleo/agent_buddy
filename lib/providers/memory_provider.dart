import 'package:flutter/foundation.dart';

import '../models/memory.dart';
import '../services/memory_repository.dart';

class MemoryProvider extends ChangeNotifier {
  MemoryProvider(this._repo);

  final MemoryRepository _repo;

  List<Memory> list({
    String? keyword,
    List<String>? keywords,
    List<String>? tags,
    int max = 200,
  }) {
    return _repo.list(
      keyword: keyword,
      keywords: keywords,
      tags: tags,
      max: max,
    );
  }

  Future<Memory> addUser({
    required String content,
    List<String> tags = const [],
  }) async {
    final m = await _repo.add(content: content, source: 'user', tags: tags);
    notifyListeners();
    return m;
  }

  Future<Memory?> update({
    required String id,
    String? content,
    String? source,
    List<String>? tags,
  }) async {
    final updated = await _repo.update(
      id: id,
      content: content,
      source: source,
      tags: tags,
    );
    if (updated != null) notifyListeners();
    return updated;
  }

  Future<bool> delete(String id) async {
    final ok = await _repo.delete(id);
    if (ok) notifyListeners();
    return ok;
  }

  Future<void> deleteMany(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _repo.deleteMany(list);
    notifyListeners();
  }

  int get length => _repo.length;
}
