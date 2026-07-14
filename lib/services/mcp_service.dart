import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOSink, Platform, Process, ProcessStartMode;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:http/http.dart' as http;

import '../models/mcp_provider.dart';
import 'mcp_stdio_line_reader.dart';

class _McpCacheEntry {
  final List<McpToolDef> tools;
  final int fetchedAtMs;

  _McpCacheEntry(this.tools)
    : fetchedAtMs = DateTime.now().millisecondsSinceEpoch;

  static const _ttlMs = 60_000;

  bool get isFresh =>
      DateTime.now().millisecondsSinceEpoch - fetchedAtMs < _ttlMs;
}

class McpService {
  McpService({http.Client? httpClient}) {
    if (httpClient != null) {
      _client = httpClient;
      _ownsClient = false;
    }
  }

  late http.Client _client = http.Client();
  late bool _ownsClient = true;
  final Map<String, _McpCacheEntry> _cache = {};

  /// Returns cached tools for [server] if fresh, otherwise discovers
  /// them via `tools/list`. Returns an empty list on error (never
  /// throws).
  Future<List<McpToolDef>> getServerTools(McpProvider server) async {
    final entry = _cache[server.id];
    if (entry != null && entry.isFresh) return entry.tools;
    try {
      final tools = await discoverTools(server);
      _cache[server.id] = _McpCacheEntry(tools);
      return tools;
    } catch (_) {
      // Return stale cache if available, otherwise empty.
      if (entry != null) return entry.tools;
      return const [];
    }
  }

  /// Force-refresh the tool list for [server] and return it.
  Future<List<McpToolDef>> refreshServerTools(McpProvider server) async {
    _cache.remove(server.id);
    return getServerTools(server);
  }

  /// Discover available tools from an MCP server.
  Future<List<McpToolDef>> discoverTools(McpProvider server) async {
    switch (server.transportType) {
      case McpTransportType.http:
        return _discoverToolsHttp(server);
      case McpTransportType.stdio:
        return _discoverToolsStdio(server);
    }
  }

  /// Call a tool on an MCP server.
  Future<String> callTool({
    required McpProvider server,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) async {
    switch (server.transportType) {
      case McpTransportType.http:
        return _callToolHttp(server, toolName, arguments);
      case McpTransportType.stdio:
        return _callToolStdio(server, toolName, arguments);
    }
  }

  // ---- HTTP transport ----

  Future<List<McpToolDef>> _discoverToolsHttp(McpProvider server) async {
    final url = server.serverUrl;
    if (url.isEmpty) return [];

    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/list',
      'params': {},
    });

    try {
      final response = await _client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json', ...server.headers},
        body: body,
      );
      if (response.statusCode != 200) {
        throw McpException('Server returned ${response.statusCode}');
      }
      return _parseToolListResponse(response.body);
    } catch (e) {
      if (e is McpException) rethrow;
      throw McpException('$e');
    }
  }

  Future<String> _callToolHttp(
    McpProvider server,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final url = server.serverUrl;
    if (url.isEmpty) throw McpException('MCP server URL is empty');

    final id = _nextId();
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': toolName, 'arguments': arguments},
    });

    try {
      final response = await _client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json', ...server.headers},
        body: body,
      );
      if (response.statusCode != 200) {
        throw McpException('MCP error: server returned ${response.statusCode}');
      }
      return _parseToolCallResponse(response.body);
    } catch (e) {
      if (e is McpException) rethrow;
      throw McpException('$e');
    }
  }

  // ---- Stdio transport (desktop only) ----

  bool get _stdioSupported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  Future<List<McpToolDef>> _discoverToolsStdio(McpProvider server) async {
    if (!_stdioSupported) {
      throw McpException('stdio MCP 仅支持桌面平台');
    }
    final result = await _stdioRequest(server, 'tools/list', {});
    return _parseToolListResponse(result);
  }

  Future<String> _callToolStdio(
    McpProvider server,
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    if (!_stdioSupported) {
      throw McpException('stdio MCP 仅支持桌面平台');
    }
    final result = await _stdioRequest(server, 'tools/call', {
      'name': toolName,
      'arguments': arguments,
    });
    return _parseToolCallResponse(result);
  }

  /// Spawn the MCP server process, perform the MCP initialize
  /// handshake, send the JSON-RPC request, read the response, then
  /// kill the process.
  Future<String> _stdioRequest(
    McpProvider server,
    String method,
    Map<String, dynamic> params,
  ) async {
    final cmdRaw = server.command;
    if (cmdRaw == null) throw McpException('MCP 配置缺少 command 字段');
    final argsRaw = server.commandArgs;
    final env = server.commandEnv;

    final String cmd;
    final List<String> args;
    if (Platform.isWindows) {
      final fixed = wrapWindowsCommand(cmdRaw, argsRaw);
      cmd = fixed.$1;
      args = fixed.$2;
    } else {
      cmd = cmdRaw;
      args = argsRaw;
    }

    Process? process;
    final stderrBuffer = StringBuffer();
    McpStdioLineReader? reader;
    try {
      process = await Process.start(
        cmd,
        args,
        environment: env.isNotEmpty ? env : null,
        mode: ProcessStartMode.normal,
      );

      // Drain stderr into a buffer so we can surface it in error
      // messages (e.g. "npx cannot find module X" or "node not
      // found"). The stream is single-subscriber; we must read it
      // or the OS pipe can fill up and stall the child.
      process.stderr.listen(
        (chunk) {
          stderrBuffer.write(utf8.decode(chunk, allowMalformed: true));
        },
        onError: (_) {},
        onDone: () {},
      );

      // Single long-lived subscription on stdout; the reader
      // dispatches incoming lines to whichever call is currently
      // waiting. This is the fix for "stream has already been
      // listened to" — previously each request created a fresh
      // subscription on `process.stdout` (a single-subscription
      // stream), and the second one threw as soon as the
      // initialize handshake started succeeding.
      reader = McpStdioLineReader(process.stdout, stderrBuffer: stderrBuffer);

      // ---- MCP initialize handshake ----
      // The protocol requires an initialize request before any other
      // method call. Without it, many servers silently wait forever.
      final initId = _nextId();
      await _stdioSend(
        process.stdin,
        _buildRequest(initId, 'initialize', {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'agent-buddy', 'version': '1.0.0'},
        }),
      );
      await reader.nextLine(
        expectedId: initId.toString(),
        timeout: _stdioRequestTimeout,
      );

      // Send the initialized notification (no response expected).
      await _stdioSend(
        process.stdin,
        _buildRequest(_nextId(), 'notifications/initialized', {}),
      );

      // ---- Actual request ----
      final reqId = _nextId();
      await _stdioSend(process.stdin, _buildRequest(reqId, method, params));
      final raw = await reader.nextLine(
        expectedId: reqId.toString(),
        timeout: _stdioRequestTimeout,
      );
      return raw;
    } catch (e) {
      if (e is McpException) rethrow;
      final stderrTail = stderrBuffer.toString().trim();
      if (stderrTail.isNotEmpty) {
        throw McpException('$e (stderr: $stderrTail)');
      }
      throw McpException('$e');
    } finally {
      try {
        await reader?.close();
        process?.stdin.close();
        process?.kill();
        await process?.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () => -1,
        );
      } catch (_) {}
    }
  }

  String _buildRequest(int id, String method, Map<String, dynamic> params) =>
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      });

  Future<void> _stdioSend(IOSink stdin, String request) async {
    stdin.writeln(request);
    await stdin.flush();
  }

  // ---- Response parsing ----

  List<McpToolDef> _parseToolListResponse(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data case {'error': Map<String, dynamic> err}) {
      throw McpException('${err['message'] ?? 'unknown error'}');
    }
    final result = data['result'] as Map<String, dynamic>?;
    if (result == null) throw McpException('no result in response');
    final tools = result['tools'] as List<dynamic>? ?? [];
    return tools
        .map((t) => McpToolDef.fromJson(t as Map<String, dynamic>))
        .toList();
  }

  String _parseToolCallResponse(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if (data case {'error': Map<String, dynamic> err}) {
      throw McpException('${err['message'] ?? 'unknown error'}');
    }
    final result = data['result'] as Map<String, dynamic>?;
    if (result == null) throw McpException('no result in response');
    final content = result['content'] as List<dynamic>? ?? [];
    final texts = content
        .whereType<Map<String, dynamic>>()
        .where((c) => c['type'] == 'text')
        .map((c) => c['text'] as String? ?? '')
        .where((t) => t.isNotEmpty)
        .toList();
    return texts.isEmpty ? jsonEncode(result) : texts.join('\n');
  }

  int _nextIdCounter = 1;
  int _nextId() => _nextIdCounter++;

  /// Per-request stdio timeout. Generous because `npx -y <pkg>` may
  /// need to download and install the package on the first run
  /// (several minutes on a slow network is possible).
  static const Duration _stdioRequestTimeout = Duration(seconds: 300);

  /// Wraps a Windows command with `cmd /c` so that `.cmd` / `.bat`
  /// scripts (`npx`, `npm`, etc.) can be found and executed.
  ///
  /// Windows' `CreateProcessW` only searches PATH for `.exe` files,
  /// so `Process.start('npx', ...)` fails with "file not found" on a
  /// standard npm install. `cmd /c npx ...` works because
  /// `cmd.exe` honors `PATHEXT` and resolves `.cmd` / `.bat`.
  ///
  /// If the caller already specified `cmd` / `cmd.exe` as the entry
  /// point, we keep their chosen command and just make sure `/c` (or
  /// `/k`) is the first argument — previously the code dropped the
  /// `/c` flag entirely, which left `cmd.exe` in interactive mode
  /// after a "command not recognized" error and caused the 120s
  /// timeout the user was seeing.
  @visibleForTesting
  static (String, List<String>) wrapWindowsCommand(
    String cmd,
    List<String> args,
  ) {
    if (_isWindowsShell(cmd)) {
      if (args.isEmpty || (args[0] != '/c' && args[0] != '/k')) {
        return (cmd, ['/c', ...args]);
      }
      return (cmd, args);
    }
    return ('cmd', ['/c', cmd, ...args]);
  }

  static bool _isWindowsShell(String cmd) {
    final lower = cmd.toLowerCase();
    return lower == 'cmd' || lower == 'cmd.exe';
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}

class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => message;
}
