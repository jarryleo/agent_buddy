import 'dart:convert';

import 'package:agent_buddy/models/mcp_provider.dart';
import 'package:agent_buddy/services/mcp_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('McpService.wrapWindowsCommand', () {
    test('wraps a bare npx command with cmd /c', () {
      final out = McpService.wrapWindowsCommand('npx', ['-y', 'foo']);
      expect(out.$1, 'cmd');
      expect(out.$2, ['/c', 'npx', '-y', 'foo']);
    });

    test('wraps a bare npx with empty args', () {
      final out = McpService.wrapWindowsCommand('npx', const []);
      expect(out.$1, 'cmd');
      expect(out.$2, ['/c', 'npx']);
    });

    test('wraps a .exe absolute path with cmd /c', () {
      final out = McpService.wrapWindowsCommand(r'C:\Tools\server.exe', [
        '--port',
        '8080',
      ]);
      expect(out.$1, 'cmd');
      expect(out.$2, [r'/c', r'C:\Tools\server.exe', '--port', '8080']);
    });

    test('preserves user-supplied cmd /c as-is', () {
      final out = McpService.wrapWindowsCommand('cmd', [
        '/c',
        'npx',
        '-y',
        'bing-cn-mcp',
      ]);
      expect(out.$1, 'cmd');
      expect(out.$2, ['/c', 'npx', '-y', 'bing-cn-mcp']);
    });

    test('preserves user-supplied cmd /k as-is', () {
      final out = McpService.wrapWindowsCommand('cmd', ['/k', 'npx', 'foo']);
      expect(out.$1, 'cmd');
      expect(out.$2, ['/k', 'npx', 'foo']);
    });

    test('patches missing /c on user-supplied cmd', () {
      // The TODO.md chrome-devtools example used this broken shape —
      // it would leave cmd.exe in interactive mode and the test
      // would hang until the timeout fired.
      final out = McpService.wrapWindowsCommand('cmd', [
        'npx',
        '-y',
        'chrome-devtools-mcp@latest',
      ]);
      expect(out.$1, 'cmd');
      expect(out.$2, ['/c', 'npx', '-y', 'chrome-devtools-mcp@latest']);
    });

    test('handles cmd.exe (case-insensitive) the same as cmd', () {
      final out1 = McpService.wrapWindowsCommand('cmd.exe', ['npx', 'foo']);
      expect(out1.$1, 'cmd.exe');
      expect(out1.$2, ['/c', 'npx', 'foo']);

      final out2 = McpService.wrapWindowsCommand('CMD.EXE', ['npx', 'foo']);
      expect(out2.$1, 'CMD.EXE');
      expect(out2.$2, ['/c', 'npx', 'foo']);
    });

    test('patches missing /c on user-supplied cmd with empty args', () {
      final out = McpService.wrapWindowsCommand('cmd', const []);
      expect(out.$1, 'cmd');
      expect(out.$2, ['/c']);
    });
  });

  group('McpService HTTP transport', () {
    test('discoverTools posts tools/list and parses the result', () async {
      final client = MockClient((req) async {
        expect(req.method, 'POST');
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['method'], 'tools/list');
        return http.Response(
          '{"jsonrpc":"2.0","id":1,"result":{"tools":['
          '{"name":"echo","description":"echo back","inputSchema":'
          '{"type":"object","properties":{"text":{"type":"string"}}}}'
          ']}}',
          200,
          headers: {'Content-Type': 'application/json'},
        );
      });
      final mcp = McpService(httpClient: client);
      try {
        final server = McpProvider(
          id: 'test',
          name: 'http test',
          jsonConfig: '{"url":"https://example.com/mcp"}',
        );
        final tools = await mcp.discoverTools(server);
        expect(tools, hasLength(1));
        expect(tools.first.name, 'echo');
        expect(tools.first.description, 'echo back');
        expect(tools.first.inputSchema['properties']['text']['type'], 'string');
      } finally {
        mcp.dispose();
      }
    });

    test('discoverTools surfaces HTTP error as McpException', () async {
      final client = MockClient((req) async {
        return http.Response('upstream broken', 502);
      });
      final mcp = McpService(httpClient: client);
      try {
        final server = McpProvider(
          id: 'test',
          name: 'http test',
          jsonConfig: '{"url":"https://example.com/mcp"}',
        );
        await expectLater(
          mcp.discoverTools(server),
          throwsA(
            isA<McpException>().having(
              (e) => e.message,
              'message',
              contains('502'),
            ),
          ),
        );
      } finally {
        mcp.dispose();
      }
    });

    test('discoverTools surfaces JSON-RPC error.message', () async {
      final client = MockClient((req) async {
        return http.Response(
          '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"bad"}}',
          200,
        );
      });
      final mcp = McpService(httpClient: client);
      try {
        final server = McpProvider(
          id: 'test',
          name: 'http test',
          jsonConfig: '{"url":"https://example.com/mcp"}',
        );
        await expectLater(
          mcp.discoverTools(server),
          throwsA(
            isA<McpException>().having((e) => e.message, 'message', 'bad'),
          ),
        );
      } finally {
        mcp.dispose();
      }
    });

    test('callTool joins text content blocks with newlines', () async {
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['method'], 'tools/call');
        expect(body['params']['name'], 'echo');
        return http.Response(
          '{"jsonrpc":"2.0","id":2,"result":{"content":['
          '{"type":"text","text":"hello "},'
          '{"type":"text","text":"world"}'
          ']}}',
          200,
        );
      });
      final mcp = McpService(httpClient: client);
      try {
        final server = McpProvider(
          id: 'test',
          name: 'http test',
          jsonConfig: '{"url":"https://example.com/mcp"}',
        );
        final result = await mcp.callTool(
          server: server,
          toolName: 'echo',
          arguments: const {'text': 'hello world'},
        );
        expect(result, 'hello \nworld');
      } finally {
        mcp.dispose();
      }
    });
  });

  group('McpProvider transport detection', () {
    test('detects stdio when command is set', () {
      final p = McpProvider(
        id: '1',
        name: 'std',
        jsonConfig: '{"command":"npx","args":["-y","foo"]}',
      );
      expect(p.transportType, McpTransportType.stdio);
      expect(p.command, 'npx');
      expect(p.commandArgs, ['-y', 'foo']);
    });

    test('detects stdio when command is cmd (with or without /c)', () {
      final p1 = McpProvider(
        id: '1',
        name: 'cmd-broken',
        jsonConfig: '{"command":"cmd","args":["npx","-y","foo"]}',
      );
      expect(p1.transportType, McpTransportType.stdio);

      final p2 = McpProvider(
        id: '2',
        name: 'cmd-good',
        jsonConfig: '{"command":"cmd","args":["/c","npx","-y","foo"]}',
      );
      expect(p2.transportType, McpTransportType.stdio);
    });

    test('detects http when url is set', () {
      final p = McpProvider(
        id: '1',
        name: 'http',
        jsonConfig:
            '{"url":"https://example.com/mcp","headers":{"X-Token":"abc"}}',
      );
      expect(p.transportType, McpTransportType.http);
      expect(p.serverUrl, 'https://example.com/mcp');
      expect(p.headers, {'X-Token': 'abc'});
    });

    test('detects http when raw config is a plain URL', () {
      final p = McpProvider(
        id: '1',
        name: 'http',
        jsonConfig: 'https://example.com/mcp',
      );
      expect(p.transportType, McpTransportType.http);
      expect(p.serverUrl, 'https://example.com/mcp');
    });

    test('unwraps the mcpServers wrapper when present', () {
      final p = McpProvider(
        id: '1',
        name: 'wrapped',
        jsonConfig:
            '{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","x"]}}}',
      );
      expect(p.transportType, McpTransportType.stdio);
      expect(p.command, 'npx');
      expect(p.commandArgs, ['-y', 'x']);
    });

    test('parses env entries as strings', () {
      final p = McpProvider(
        id: '1',
        name: 'env',
        jsonConfig:
            '{"command":"node","args":["server.js"],"env":{"PORT":3000,"DEBUG":true}}',
      );
      expect(p.commandEnv, {'PORT': '3000', 'DEBUG': 'true'});
    });
  });
}
