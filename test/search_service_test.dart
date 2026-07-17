import 'dart:io';

import 'package:agent_buddy/services/search_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SearchService.search (regex + walk)', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('search_service_test_');
    });
    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Future<void> writeFile(String rel, String content) async {
      final f = File(p.join(root.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
    }

    test('finds a single match with line + column', () async {
      await writeFile('a.txt', 'hello world\nfoo bar\nbaz\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'foo', rootAbs: root.path),
      );
      expect(result.totalMatches, 1);
      expect(result.files, hasLength(1));
      final file = result.files.first;
      expect(file.path, p.join('a.txt'));
      expect(file.matches, hasLength(1));
      final m = file.matches.first;
      expect(m.line, 2);
      expect(m.column, 1);
      expect(m.matchStart, 0);
      expect(m.matchEnd, 3);
      expect(m.text, 'foo bar');
    });

    test('reports every match across multiple files', () async {
      await writeFile('a.dart', 'one\nTODO: fix\nthree\n');
      await writeFile('b.dart', 'TODO later\n');
      await writeFile('c.txt', 'no match here\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path),
      );
      expect(result.totalMatches, 2);
      final files = {for (final f in result.files) f.path: f.matches.length};
      expect(files[p.join('a.dart')], 1);
      expect(files[p.join('b.dart')], 1);
      expect(files.containsKey(p.join('c.txt')), isFalse);
    });

    test('multiLine regex matches across lines', () async {
      await writeFile('a.txt', 'line1\nline2\nline3\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(
          pattern: 'line1\\nline2',
          rootAbs: root.path,
          caseSensitive: true,
        ),
      );
      expect(result.totalMatches, 1);
      final m = result.files.first.matches.first;
      expect(m.line, 1);
      expect(m.text.startsWith('line1'), isTrue);
    });

    test('case-insensitive by default', () async {
      await writeFile('a.txt', 'Hello\nHELLO\nhello\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'hello', rootAbs: root.path),
      );
      expect(result.totalMatches, 3);
    });

    test('case-sensitive when requested', () async {
      await writeFile('a.txt', 'Hello\nHELLO\nhello\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'hello', rootAbs: root.path, caseSensitive: true),
      );
      expect(result.totalMatches, 1);
    });

    test('include_glob filters to a single extension', () async {
      await writeFile('a.dart', 'TODO: dart\n');
      await writeFile('b.txt', 'TODO: text\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path, includeGlob: '*.dart'),
      );
      expect(result.totalMatches, 1);
      expect(result.files.single.path, p.join('a.dart'));
    });

    test('exclude_glob drops generated files', () async {
      await writeFile('a.g.dart', 'part of generated\n');
      await writeFile('b.dart', 'part of generated\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(
          pattern: 'generated',
          rootAbs: root.path,
          includeGlob: '*.dart',
          excludeGlob: '*.g.dart',
        ),
      );
      expect(result.totalMatches, 1);
      expect(result.files.single.path, p.join('b.dart'));
    });

    test('include_glob with ** matches nested files', () async {
      await writeFile('lib/src/a.dart', 'nested match\n');
      await writeFile('test/a_test.dart', 'test file\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(
          pattern: 'nested',
          rootAbs: root.path,
          includeGlob: 'lib/**/*.dart',
        ),
      );
      expect(result.totalMatches, 1);
      expect(result.files.single.path, p.join('lib', 'src', 'a.dart'));
    });

    test('skips .git / node_modules / build directories', () async {
      await writeFile('.git/HEAD', 'TODO\n');
      await writeFile('node_modules/foo/index.js', 'TODO\n');
      await writeFile('build/output.txt', 'TODO\n');
      await writeFile('src/real.dart', 'TODO\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path),
      );
      expect(result.totalMatches, 1);
      expect(result.files.single.path, p.join('src', 'real.dart'));
    });

    test('skips binary files by extension', () async {
      await writeFile('logo.png', '%PNG-TODO-data\n');
      await writeFile('archive.zip', 'PKTODO-data\n');
      await writeFile('real.txt', 'TODO here\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path),
      );
      // Only `real.txt` should be scanned; the others are
      // rejected by extension before the read.
      expect(result.totalMatches, 1);
      expect(result.files.single.path, p.join('real.txt'));
    });

    test('per-file size cap drops oversized files', () async {
      final big = 'X' * (2 * 1024 * 1024); // 2 MB
      await writeFile('big.txt', 'TODO$big\n');
      await writeFile('small.txt', 'TODO\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(
          pattern: 'TODO',
          rootAbs: root.path,
          maxFileSizeBytes: 1024 * 1024, // 1 MB
        ),
      );
      expect(result.totalMatches, 1);
      expect(result.files.single.path, p.join('small.txt'));
      final errors = result.fileErrors
          .where((e) => e['file'] == p.join('big.txt'))
          .toList();
      expect(errors, hasLength(1));
      expect(errors.single['error'], contains('size'));
    });

    test('early termination at max_results', () async {
      // 100 matches spread across 5 files.
      for (var i = 0; i < 5; i++) {
        final buf = StringBuffer();
        for (var j = 0; j < 20; j++) {
          buf.writeln('TODO line $j');
        }
        await writeFile('file_$i.txt', buf.toString());
      }
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path, maxResults: 7),
      );
      expect(result.totalMatches, 7);
      expect(result.truncated, isTrue);
    });

    test('explicit files[] list is searched even when path is set', () async {
      await writeFile('walked.dart', 'TODO: walked\n');
      final other = File(
        p.join(root.parent.path, '${root.uri.pathSegments.last}_other.dart'),
      );
      await other.writeAsString('TODO: explicit\n', flush: true);
      addTearDown(() async {
        if (await other.exists()) await other.delete();
      });

      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path, files: [other.path]),
      );
      final allFiles = result.files.map((f) => f.path).toSet();
      expect(allFiles, contains(p.join('walked.dart')));
      // The sibling file lives outside the search root, so the
      // service reports it via a `..` relative path. The
      // basename is what the model cares about.
      expect(
        allFiles.any((p) => p.endsWith('_other.dart')),
        isTrue,
        reason: 'expected the outside-root file to be reported, got $allFiles',
      );
    });

    test('explicit files[] alone works (no directory walk)', () async {
      final a = File(p.join(root.path, 'a.txt'));
      await a.writeAsString('TODO\n', flush: true);
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path, files: [a.path]),
      );
      expect(result.totalMatches, 1);
      expect(result.candidateFiles, 1);
    });

    test('returns no matches cleanly when the tree is empty', () async {
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path),
      );
      expect(result.totalMatches, 0);
      expect(result.files, isEmpty);
    });

    test('throws SearchException for invalid regex', () async {
      final svc = SearchService();
      await expectLater(
        svc.search(SearchArgs(pattern: '[unclosed', rootAbs: root.path)),
        throwsA(isA<SearchException>()),
      );
    });

    test('throws SearchException for missing path', () async {
      final svc = SearchService();
      await expectLater(
        svc.search(
          SearchArgs(
            pattern: 'TODO',
            rootAbs: p.join(root.path, 'does-not-exist'),
          ),
        ),
        throwsA(isA<SearchException>()),
      );
    });

    test('throws SearchException for empty pattern', () async {
      final svc = SearchService();
      await expectLater(
        svc.search(SearchArgs(pattern: '', rootAbs: root.path)),
        throwsA(isA<SearchException>()),
      );
    });

    test('refuses to search inside a known-heavy directory by name', () async {
      final heavy = Directory(p.join(root.path, '.git'))..createSync();
      await File(p.join(heavy.path, 'HEAD')).writeAsString('TODO\n');
      final svc = SearchService();
      await expectLater(
        svc.search(SearchArgs(pattern: 'TODO', rootAbs: heavy.path)),
        throwsA(isA<SearchException>()),
      );
    });

    test('honors max_files during the walk', () async {
      for (var i = 0; i < 10; i++) {
        await writeFile('f_$i.txt', 'TODO\n');
      }
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path, maxFiles: 3),
      );
      expect(result.scannedFiles, lessThanOrEqualTo(3));
      expect(result.truncated, isTrue);
    });

    test('context_lines emits before+after arrays', () async {
      await writeFile('a.txt', 'one\ntwo\nTARGET\nfour\nfive\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TARGET', rootAbs: root.path, contextLines: 2),
      );
      final m = result.files.single.matches.single;
      expect(m.line, 3);
      expect(m.contextBefore, ['one', 'two']);
      expect(m.contextAfter, ['four', 'five']);
    });

    test('reports scanned_bytes + elapsed_ms', () async {
      await writeFile('a.txt', 'TODO\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path),
      );
      expect(result.scannedBytes, greaterThan(0));
      expect(result.elapsedMs, greaterThanOrEqualTo(0));
    });

    test('toJson produces the model-facing envelope', () async {
      await writeFile('a.txt', 'TODO\n');
      final svc = SearchService();
      final result = await svc.search(
        SearchArgs(pattern: 'TODO', rootAbs: root.path),
      );
      final json = result.toJson();
      expect(json['query'], 'TODO');
      expect(json['root'], root.path);
      expect(json['scanned_files'], 1);
      expect(json['total_matches'], 1);
      expect(json['truncated'], isFalse);
      final files = (json['files'] as List).cast<Map<String, dynamic>>();
      expect(files, hasLength(1));
      expect(files.single['file'], p.join('a.txt'));
      expect(files.single['match_count'], 1);
    });
  });

  group('SearchService.searchInMemory (mobile path)', () {
    test('searches a pre-loaded list of files', () {
      final svc = SearchService();
      final result = svc.searchInMemory(
        args: SearchArgs(pattern: 'TODO', rootAbs: '/virtual'),
        entries: [
          (path: 'working://a.dart', content: 'TODO: alpha\n'),
          (path: 'working://b.dart', content: 'no marker here\n'),
          (path: 'working://c.dart', content: 'TODO line 1\nTODO line 2\n'),
        ],
      );
      expect(result.totalMatches, 3);
      expect(result.files.map((f) => f.path).toSet(), {
        'working://a.dart',
        'working://c.dart',
      });
    });

    test('honors include_glob inside the in-memory mode', () {
      final svc = SearchService();
      final result = svc.searchInMemory(
        args: SearchArgs(
          pattern: 'TODO',
          rootAbs: '/virtual',
          includeGlob: '*.dart',
        ),
        entries: [
          (path: '/virtual/a.dart', content: 'TODO\n'),
          (path: '/virtual/b.txt', content: 'TODO\n'),
        ],
      );
      expect(result.totalMatches, 1);
      expect(result.files.single.path, '/virtual/a.dart');
    });
  });
}
