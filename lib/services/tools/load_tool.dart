import '../tool_service.dart';
import 'tool_base.dart';

/// Meta-tool that lets the model unlock a specific tool's full
/// JSON schema on demand.
///
/// The always-on base system prompt only carries a tiny "tool
/// index" (`tool id + one-line summary` for every active tool,
/// ~200 tokens total). When the model decides to actually call a
/// tool it first invokes `load_tool(...)` and the returned
/// compact markdown cheat-sheet tells it the exact action enum /
/// parameter shape / constraints. Once a tool is loaded,
/// `ChatProvider._loadedToolIds` keeps it in the `tools=[...]`
/// array for the rest of the session so the model can call it
/// directly without re-loading.
///
/// **Batch only — array required.** The schema accepts a single
/// `tool_names: string[]` parameter (no scalar fallback) so the
/// model is pushed toward unlocking every tool it might need
/// for the current task in one round-trip. This matters on
/// per-request-billed providers (some Anthropic / OpenRouter
/// endpoints) where each call is a separate billable request,
/// and on the local GGUF where each turn is a full prompt re-eval
/// — both amplify the cost of the legacy "load one tool per call"
/// pattern. A single
/// `load_tool(tool_names=["search","file","memory"])` returns
/// three manuals in one response (~one round-trip, one response
/// token block) instead of three separate calls.
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
      '按需加载指定工具的完整使用说明,**只接受数组**(一次加载多个)。'
      '返回这些工具的精简 markdown 手册(actions / 参数 / 约束),'
      '合并到同一次响应里。加载后这些工具的 schema 会进入 tools 数组,'
      '本会话内可一直直接调用,无需重复加载。';

  @override
  String get shortDescription => '批量加载工具详细手册(schema + 约束),一次可加载多个';

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
            // **Array only.** The model is pushed toward
            // batching — passing one element is technically
            // allowed but wasteful. The resolver dedupes the
            // list, so a nervous model that re-emits an id it
            // already knows about won't blow up.
            'tool_names': {
              'type': 'array',
              'items': {'type': 'string', 'enum': allowedToolIds},
              'minItems': 1,
              'description':
                  '要加载的工具 id 列表,与系统提示"工具索引"里的 id 完全一致。'
                  'MCP 工具填 mcp__<server>__<tool>。'
                  '一次传多个 = 一次 round-trip 拿到所有手册 '
                  '(per-request-billed provider 上的核心省钱点)。',
            },
          },
          'required': ['tool_names'],
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
