import 'dart:io';

import 'package:agent_buddy/services/platform/file_service_impl.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FileServiceImpl in flutter test runner', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = await Directory.systemTemp.createTemp('file_service_');
    final docs = Directory('${root.path}/docs');
    final temp = Directory('${root.path}/temp');
    final support = Directory('${root.path}/support');
    await docs.create(recursive: true);
    await temp.create(recursive: true);
    await support.create(recursive: true);
    debugPrint('sandbox: ${root.path}');

    final svc = FileServiceImpl(
      overrideDocs: Future.value(docs),
      overrideTemp: Future.value(temp),
      overrideSupport: Future.value(support),
    );

    await svc.write('app://documents/x/y.txt', 'hello'.codeUnits);
    final xDir = Directory('${root.path}/docs${Platform.pathSeparator}x');
    debugPrint('xDir.existsSync: ${xDir.existsSync()}');
    debugPrint(
      'xDir.listSync: '
      '${xDir.listSync().map((e) => e.path).toList()}',
    );
    try {
      final asyncList = await Directory('${root.path}/docs/x').list().toList();
      debugPrint('async list (same as xDir): ${asyncList.length} entries');
    } catch (e) {
      debugPrint('async list threw: $e');
    }

    try {
      await svc.delete('app://documents/x');
      debugPrint('svc.delete did NOT throw (UNEXPECTED)');
    } on Object catch (e) {
      debugPrint('svc.delete threw: $e');
    }

    await root.delete(recursive: true);
  });
}
