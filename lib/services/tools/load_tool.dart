import '../tool_service.dart';
import 'tool_base.dart';

/// Meta-tool that lets the model unlock a specific tool's full
/// JSON schema on demand.
///
/// The always-on base system prompt only carries a tiny "tool
/// index" (`tool id + one-line summary` for every active tool,
/// ~200 tokens total). When the model decides to actually call a
/// tool it first invokes `load_tool(tool_name="...")` and the
/// returned compact markdown cheat-sheet tells it the exact
/// action enum / parameter shape / constraints. Once a tool is
/// loaded, `ChatProvider._loadedToolIds` keeps it in the
/// `tools=[...]` array for the rest of the session so the model
/// can call it directly without re-loading.
///
/// The full schema is still emitted to the model in the
/// `tools=[...]` array (so the function-call parser knows the
/// argument shape); `load_tool` exists primarily so the
/// *markdown response* side carries the human-readable
/// constraints the JSON Schema can't easily express
/// (e.g. "`old_text` 必须唯一").
class LoadTool extends ToolBase {
  @override
  String get id => 'load_tool';

  @override
  String get name => '加载工具';

  @override
  String get description =>
      '按需加载指定工具的完整使用说明。返回该工具的精简 markdown 手册 '
      '(actions / 参数 / 约束)。加载后该工具的 schema 会进入 tools 数组,'
      '本会话内可一直直接调用,无需重复加载。';

  @override
  String get shortDescription =>
      '按需加载工具的详细使用手册(schema + 约束)';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  /// List of tool ids the model is allowed to load. Built
  /// per-call from the live settings so disabled / unsupported
  /// tools never appear in the enum. Excludes `load_tool` itself.
  ///
  /// `ChatProvider._loadTool` walks [ToolRegistry] for the
  /// resolved id, so the runtime check is the source of truth;
  /// the enum is just a soft hint to the model.
  List<String> allowedToolIds = const [];

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'load_tool',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'tool_name': {
              'type': 'string',
              'description':
                  '工具 id,与系统提示"工具索引"里的 name 完全一致。'
                  'MCP 工具填 mcp__<server>__<tool>',
              'enum': allowedToolIds,
            },
          },
          'required': ['tool_name'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    throw ToolException(
      'load_tool is handled by ChatProvider; do not call execute() directly',
    );
  }
}