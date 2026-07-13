import 'dart:async';
import 'dart:convert';

import 'package:agent_buddy/services/mcp_service.dart';
import 'package:agent_buddy/services/mcp_stdio_line_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('McpStdioLineReader', () {
    test('returns the next line for the expected id', () async {
      final controller = StreamController<List<int>>();
      final reader = McpStdioLineReader(
        controller.stream,
        stderrBuffer: StringBuffer(),
      );
      addTearDown(() async {
        await reader.close();
        await controller.close();
      });

      controller.add(utf8.encode('{"jsonrpc":"2.0","id":1,"result":{}}\n'));
      final line = await reader.nextLine(
        expectedId: '1',
        timeout: const Duration(seconds: 1),
      );
      expect(line, '{"jsonrpc":"2.0","id":1,"result":{}}');
    });

    test(
      'handles multiple nextLine calls without re-subscribing to stdout',
      () async {
        // Regression for "Bad state: Stream has already been
        // listened to" — multiple nextLine() invocations on the
        // same reader must reuse a single underlying subscription.
        final controller = StreamController<List<int>>();
        final reader = McpStdioLineReader(
          controller.stream,
          stderrBuffer: StringBuffer(),
        );
        addTearDown(() async {
          await reader.close();
          await controller.close();
        });

        // First call: id=1
        final first = reader.nextLine(
          expectedId: '1',
          timeout: const Duration(seconds: 1),
        );
        controller.add(utf8.encode(
          '{"jsonrpc":"2.0","id":1,"result":{"phase":"init"}}\n',
        ));
        expect(await first, contains('"id":1'));

        // Second call: id=2 — this is the one that would have
        // thrown the stream-already-listened error before the fix.
        final second = reader.nextLine(
          expectedId: '2',
          timeout: const Duration(seconds: 1),
        );
        controller.add(utf8.encode(
          '{"jsonrpc":"2.0","id":2,"result":{"phase":"request"}}\n',
        ));
        expect(await second, contains('"id":2'));
      },
    );

    test('buffers non-matching lines until the matching id is requested',
        () async {
      // Simulates: response to id=2 arrives before we even ask for
      // it, then we ask for id=2 later and get the buffered line.
      final controller = StreamController<List<int>>();
      final reader = McpStdioLineReader(
        controller.stream,
        stderrBuffer: StringBuffer(),
      );
      addTearDown(() async {
        await reader.close();
        await controller.close();
      });

      // Send the id=2 response up front, before any waiter exists.
      controller.add(utf8.encode(
        '{"jsonrpc":"2.0","id":2,"result":{"x":1}}\n',
      ));
      // Let the microtask drain so the listener has buffered the line.
      await Future<void>.delayed(Duration.zero);

      // Now ask for id=2 — should return from the buffer.
      final line = await reader.nextLine(
        expectedId: '2',
        timeout: const Duration(seconds: 1),
      );
      expect(line, contains('"id":2'));
    });

    test('strips a UTF-8 BOM from the first line', () async {
      final controller = StreamController<List<int>>();
      final reader = McpStdioLineReader(
        controller.stream,
        stderrBuffer: StringBuffer(),
      );
      addTearDown(() async {
        await reader.close();
        await controller.close();
      });

      // 0xEF 0xBB 0xBF is the UTF-8 BOM.
      final bytes = [
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('{"jsonrpc":"2.0","id":7,"result":{}}\n'),
      ];
      controller.add(bytes);

      final line = await reader.nextLine(
        expectedId: '7',
        timeout: const Duration(seconds: 1),
      );
      // The returned line must not start with the BOM, otherwise
      // jsonDecode would reject it.
      expect(line.codeUnitAt(0), isNot(0xFEFF));
      expect(line, contains('"id":7'));
    });

    test('times out and includes stderr tail in the error message',
        () async {
      final stderr = StringBuffer();
      final controller = StreamController<List<int>>();
      final reader = McpStdioLineReader(
        controller.stream,
        stderrBuffer: stderr,
      );
      addTearDown(() async {
        await reader.close();
        await controller.close();
      });

      stderr.write("npx: command not found\n");

      await expectLater(
        reader.nextLine(
          expectedId: '42',
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<McpException>()
              .having((e) => e.message, 'message', contains('超时'))
              .having(
                (e) => e.message,
                'message',
                contains('npx: command not found'),
              ),
        ),
      );
    });

    test('flushes buffered matching line on onDone', () async {
      // The process writes a response then exits; the waiter should
      // still receive the buffered line.
      final controller = StreamController<List<int>>();
      final reader = McpStdioLineReader(
        controller.stream,
        stderrBuffer: StringBuffer(),
      );
      addTearDown(() async {
        await reader.close();
        await controller.close();
      });

      final first = reader.nextLine(
        expectedId: '5',
        timeout: const Duration(seconds: 1),
      );
      controller.add(utf8.encode(
        '{"jsonrpc":"2.0","id":5,"result":{"ok":true}}\n',
      ));
      // Close stdout before awaiting the future.
      await controller.close();

      final line = await first;
      expect(line, contains('"id":5'));
    });

    test('errors with descriptive message on onDone with no buffered line',
        () async {
      final stderr = StringBuffer();
      final controller = StreamController<List<int>>();
      final reader = McpStdioLineReader(
        controller.stream,
        stderrBuffer: stderr,
      );
      addTearDown(() async {
        await reader.close();
      });

      stderr.write('boom\n');

      final first = reader.nextLine(
        expectedId: '9',
        timeout: const Duration(seconds: 1),
      );
      await controller.close();

      await expectLater(
        first,
        throwsA(
          isA<McpException>().having(
            (e) => e.message,
            'message',
            allOf(contains('意外退出'), contains('boom')),
          ),
        ),
      );
    });
  });
}
