import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

/// `todo` tool — manages a per-conversation task list the model
/// uses to plan + track a multi-step task.
///
/// **What it does for the model** — instead of leaving the user
/// guessing "what's the model doing right now", the model emits a
/// `todo` list at the start of a long task and ticks items off as
/// it works through them. The chat input area renders the list
/// above the text field so the user can see live progress.
///
/// **What it does for the chat provider** — when the model's turn
/// ends with unfinished items, the chat provider auto-injects a
/// hidden supervision prompt ("[任务监督] 任务清单还有 N 项未完成,
/// 请继续...") so the model resumes the work without the user
/// having to ping it. The user can stop that supervision by
/// either (a) tapping "stop" while the model is working
/// (the chat provider flips a per-turn flag), or (b) hitting the
/// panel's "放弃任务 / abandon" button which clears the list.
///
/// **Why the tool is a thin shim here** — the todo list is
/// *per-session* state owned by `ChatProvider` (so it lives on
/// the active `ChatSession` and is persisted to Hive). Direct
/// execution from `ToolService` would force a singleton on the
/// service container, which would break the multi-session /
/// per-conversation invariant. So `execute()` throws a
/// `ToolException` to route the call back into
/// `ChatProvider._onToolCall`, which is the only path that
/// can supply the per-session config the action handlers need
/// (see [TodoTool.runAction]).
class TodoTool extends ToolBase {
  @override
  String get id => 'todo';

  @override
  String get name => '任务清单';

  @override
  String get description =>
      '管理**本轮对话**的任务清单。'
      '长任务(>=3 步)开始前**必须**先 create + add 把任务列出来,'
      '然后每完成一项就 complete 一项,让用户实时看到进度。';

  @override
  String get shortDescription => '本轮对话的任务清单(显示在输入框上方)';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  bool get isEnabledByDefault => true;

  @override
  String get compactSchemaForModel => '''
参数:
- action (string, 必填): create | add | complete | update | remove | list | get | clear | abandon
- create: title (string, 可选) — 给清单起一个名字(比如 "调研 OpenAI 缓存")
- add: content (string, 必填);detail (string, 可选) — 新增一项待办
- complete: id (string, 必填) — 把指定项标记为完成
- update: id (string, 必填);content (string, 可选);detail (string, 可选) — 改文案(状态保持不变)
- remove: id (string, 必填) — 删掉一项(慎用,通常用 complete 而不是 remove)
- list: 无额外参数 — 返回当前清单(含已完成项)
- get: id (string, 必填) — 取单项
- clear: 无额外参数 — 清空整个清单(用户主动放弃时调用)
- abandon: 无额外参数 — 同 clear,但语义为"用户明确放弃这个任务",用于模型明确告诉用户已停止监督

返回: {action, ok?, list?, item?, removed?, count?, completed?, total?}

使用约定:
- **长任务开始**(>=3 步):先 todo(action='create', title='<任务名>'),然后**同轮**发多个 add 把任务列出来。
- **每完成一项**:立刻 todo(action='complete', id='<id>')。别攒到最后才勾,用户看不到进度。
- **任务结束**:全部 done 之后**不要**调 clear — 让面板自然隐藏(全部 done 后 UI 自动收起)。
- **用户换任务 / 放弃**:clear 当前清单,然后重新 create + add。
- **不要**把"任务清单"和"长期记忆"混用 — memory 跨会话,todo 只在**本轮对话**内有效。
- 普通闲聊、单步查询无需调用 todo(节省一轮工具往返)。
''';

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'todo',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': const [
                'create',
                'add',
                'complete',
                'update',
                'remove',
                'list',
                'get',
                'clear',
                'abandon',
              ],
              'description':
                  '操作: create/add/complete/update/remove/list/get/clear/abandon',
            },
            // create
            'title': {'type': 'string', 'description': 'create 时使用:清单的名字'},
            // add
            'content': {
              'type': 'string',
              'description': 'add 必填;update 可选。单行文案,显示在面板上',
            },
            'detail': {
              'type': 'string',
              'description': 'add / update 时使用:次级说明(显示在 content 下方的灰色小字)',
            },
            // complete / update / remove / get
            'id': {
              'type': 'string',
              'description': 'complete/update/remove/get 时必填',
            },
          },
          'required': const ['action'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    // The todo list is owned by ChatProvider (per-session,
    // persisted to Hive). ToolService doesn't have a handle to
    // the active ChatProvider, so we always route through
    // ChatProvider._onToolCall, which is the only path that
    // can supply the per-session state. The shape mirrors how
    // `subagent.delegate` and `ask_user` work — both throw here
    // and resolve in the chat provider.
    throw ToolException(
      'todo requires per-session state and is handled by the chat provider',
    );
  }

  /// Called by `ChatProvider._onToolCall`. Routes the model call
  /// through the provided [handler], which is the chat provider's
  /// per-session dispatcher. Exposed as a static so the chat
  /// provider doesn't have to import the concrete tool class to
  /// call into it (and so tests can substitute a fake).
  static Future<String> runAction(
    Map<String, dynamic> args,
    Future<String> Function(Map<String, dynamic>) handler,
  ) {
    return handler(args);
  }

  /// Pure helper that serializes a list snapshot for the
  /// model's `list` / `create` / `clear` / `add` responses.
  /// Exposed as `@visibleForTesting`-style public so the chat
  /// provider doesn't have to duplicate the JSON shape.
  static Map<String, dynamic> serializeList(Map<String, dynamic> envelope) =>
      envelope;
}

/// JSON encoding helper used by the chat provider when handing
/// the tool result back to the model. Kept here so the wire
/// shape lives next to the schema (rather than scattered across
/// the provider).
String encodeTodoEnvelope(Map<String, dynamic> envelope) =>
    jsonEncode(envelope);
