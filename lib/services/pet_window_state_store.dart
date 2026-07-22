import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PetWindowStateStore {
  PetWindowStateStore({Directory? appDir}) : _appDir = appDir;

  final Directory? _appDir;

  Future<File> _file() async {
    final base = _appDir ?? await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(base.path, 'pets'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'window_state.json'));
  }

  Future<Offset?> loadPosition() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final x = raw['x'];
      final y = raw['y'];
      if (x is! num || y is! num) return null;
      return Offset(x.toDouble(), y.toDouble());
    } catch (_) {
      return null;
    }
  }

  Future<void> savePosition(Offset position) async {
    final file = await _file();
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'x': position.dx, 'y': position.dy}),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
