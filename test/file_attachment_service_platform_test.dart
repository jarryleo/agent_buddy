import 'dart:io';

import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/tools/tool_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_fas_platform_test_',
    );
  });

  tearDown(() async {
    resetPlatformOverrides();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('FileAttachmentService importPaths — desktop keeps the original '
      'path so the model can edit the user\'s actual file', () {
    setUp(() {
      overridePlatform(isDesktopValue: true, isMobileValue: false);
    });

    test('returns the user\'s absolute path verbatim, no copy', () async {
      // The chat input's "paste a file" path on Windows funnels
      // Explorer paths through importPaths. The desktop file
      // tool supports absolute paths (file_tool.dart:558-565
      // `_resolveDesktopPath`), so we must surface the user's
      // original path to the model — otherwise file.edit would
      // mutate a sandbox copy and the user wouldn't see the
      // change on disk.
      final source = await File(p.join(tempDir.path, 'real.txt')).create();
      await source.writeAsString('hello');

      final svc = FileAttachmentService();
      final result = await svc.importPaths([source.path]);

      expect(result, hasLength(1));
      final att = result.single;
      expect(att.name, 'real.txt');
      expect(att.path, source.path);
      // CRITICAL: the file must NOT have been copied into the
      // app sandbox — a copy would break the file tool's
      // round-trip because the model would edit a throwaway
      // file under chat_files/ and the user would never see
      // the change.
      expect(
        att.path,
        isNot(contains('chat_files')),
        reason: 'desktop must not copy attachments into the app sandbox',
      );
    });

    test('prepare() reads the original file (no copy was made)', () async {
      // End-to-end sanity check: the desktop path is read by
      // prepare() the same way it was before — only the source
      // location changed. This is what the model sees when it
      // calls file.read on the attachment's path.
      final source = await File(p.join(tempDir.path, 'readme.md')).create();
      await source.writeAsString('line one\nline two\n');

      final svc = FileAttachmentService();
      final attachments = await svc.importPaths([source.path]);
      final prepared = await svc.prepare(attachments.single);

      expect(prepared.path, source.path);
      expect(prepared.textContent, 'line one\nline two\n');
    });

    test('skips non-existent paths silently (existing behaviour)', () async {
      // Pre-existing behaviour: importPaths silently drops any
      // path that doesn't resolve. The desktop rewrite must
      // preserve this so the Windows paste path's "split into
      // image / non-image lists" flow doesn't surface a hard
      // error when a clipboard entry has gone stale.
      final svc = FileAttachmentService();
      final result = await svc.importPaths([
        p.join(tempDir.path, 'does-not-exist.txt'),
      ]);
      expect(result, isEmpty);
    });
  });

  group('FileAttachmentService importPaths — mobile still copies into '
      'the app sandbox (picker gives a transient URI outside the '
      'sandbox)', () {
    setUp(() {
      overridePlatform(isDesktopValue: false, isMobileValue: true);
    });

    test('copies into <docs>/chat_files/<µs>_<index>__<safeName>', () async {
      final source = await File(p.join(tempDir.path, 'note.txt')).create();
      await source.writeAsString('mobile');

      final svc = FileAttachmentService(docsDirResolver: () async => tempDir);
      final result = await svc.importPaths([source.path]);

      expect(result, hasLength(1));
      final att = result.single;
      expect(att.name, 'note.txt');
      expect(att.path, isNot(source.path));
      expect(att.path, contains('chat_files'));
      expect(att.path, endsWith('__note.txt'));

      // The copy actually lives on disk under chat_files/.
      expect(await File(att.path).exists(), isTrue);
    });
  });
}
