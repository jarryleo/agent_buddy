import 'package:flutter/foundation.dart';

import '../models/pet.dart';
import '../services/pet_service.dart';

/// Thin `ChangeNotifier` wrapper around [PetService]. UI code
/// subscribes to this; the service owns the on-disk state. Mutating
/// operations await [PetService] then call [notifyListeners] so the
/// settings tab rebuilds.
class PetProvider extends ChangeNotifier {
  PetProvider(this._service);

  final PetService _service;

  bool _ready = false;

  bool get isReady => _ready;

  List<Pet> get pets => _service.list();

  Pet? get builtInAnya => _service.builtInAnya;

  Pet? findById(String? id) {
    if (id == null || id.isEmpty) return null;
    return _service.get(id);
  }

  /// Materialises the bundled pet into the user pet directory and
  /// primes the cache. Idempotent — calling twice is a no-op once
  /// the seed is done.
  Future<void> ensureReady() async {
    if (_ready) return;
    await _service.ensureReady();
    _ready = true;
    notifyListeners();
  }

  /// Imports a `.zip` archive. Throws [PetImportException] on any
  /// validation failure; the caller is expected to surface a
  /// snackbar.
  Future<Pet> importFromZip(String zipPath) async {
    await ensureReady();
    final pet = await _service.importFromZip(zipPath);
    notifyListeners();
    return pet;
  }

  Future<void> delete(String id) async {
    await _service.delete(id);
    notifyListeners();
  }
}
