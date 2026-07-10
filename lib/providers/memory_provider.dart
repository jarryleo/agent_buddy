import 'package:flutter/foundation.dart';

import '../models/memory.dart';
import '../services/memory_repository.dart';

class MemoryProvider extends ChangeNotifier {
  MemoryProvider(this._repo);

  final MemoryRepository _repo;

  List<Memory> list({String? keyword, int max = 200}) {
    return _repo.list(keyword: keyword, max: max);
  }

  Future<Memory> addUser({required String content}) async {
    final m = await _repo.add(content: content, source: 'user');
    notifyListeners();
    return m;
  }

  Future<Memory?> update({
    required String id,
    String? content,
    String? source,
  }) async {
    final updated = await _repo.update(
      id: id,
      content: content,
      source: source,
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
