import '../../models/mcp_provider.dart';
import '../mcp_service.dart';
import '../tool_service.dart';
import 'tool_base.dart';

class McpTool extends ToolBase {
  /// Allows the settings provider to inject the current list of MCP
  /// server configs so the tool can pick the right server at runtime.
  static List<McpProvider> configuredServers = [];

  @override
  String get id => 'call_mcp';

  @override
  String get name => '调用 MCP 工具';

  @override
  String get description =>
      '调用已配置的 MCP (Model Context Protocol) 服务器上的工具。'
      '当前可用服务器: ${_availableServers()}';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  bool get isEnabledByDefault => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'call_mcp',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'server': {
              'type': 'string',
              'description':
                  '目标 MCP 服务器名称,必须与列表中已配置的名称完全一致。'
                  '可用服务器: ${_availableServers()}',
            },
            'tool': {'type': 'string', 'description': '要调用的工具名称'},
            'arguments': {'type': 'object', 'description': '传递给工具的参数'},
          },
          'required': ['server', 'tool', 'arguments'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final serverName = args['server'] as String? ?? '';
    final toolName = args['tool'] as String? ?? '';
    final arguments =
        (args['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};

    if (serverName.isEmpty) throw ToolException('server 不能为空');
    if (toolName.isEmpty) throw ToolException('tool 不能为空');

    final server = configuredServers.cast<McpProvider?>().firstWhere(
      (s) => s!.name == serverName,
      orElse: () => null,
    );
    if (server == null) {
      throw ToolException(
        '未找到 MCP 服务器 "$serverName"。已配置的服务器: ${_availableServers()}',
      );
    }

    final mcp = McpService();
    try {
      return await mcp.callTool(
        server: server,
        toolName: toolName,
        arguments: arguments,
      );
    } finally {
      mcp.dispose();
    }
  }

  static String _availableServers() {
    if (configuredServers.isEmpty) return '无';
    return configuredServers.map((s) => '"${s.name}"').join('、');
  }
}
