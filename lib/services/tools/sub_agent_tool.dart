import 'dart:convert';

import '../sub_agent_service.dart';
import '../tool_service.dart';
import 'tool_base.dart';

/// `subagent` tool — delegate a self-contained research task to
/// an isolated sub-agent and get back a compressed report.
///
/// **What it does for the model** — instead of polluting the main
/// conversation with a long chain of `fetch_web` / `search` tool
/// calls, the model can hand the whole task off to a sub-agent
/// that runs in its own context window. The sub-agent uses a
/// curated read-only / information-gathering toolset
/// (`fetch_web`, `search`, `current_time`, `location`, `memory`,
/// `run_command`) and a different system prompt, so its
/// intermediate tool calls and scratch text NEVER appear in the
/// main session. The main agent only sees the final compressed
/// report as a tool result.
///
/// **When to use it** — any task that the model would otherwise
/// have to do *itself* with a long tool-calling chain AND that
/// doesn't depend on the main conversation's context. Examples:
///
///   * "research the latest news on X"
///   * "look up the API for service Y and summarize the
///     authentication flow"
///   * "scan this directory for files matching pattern Z and tell
///     me which ones look like config files"
///
/// The system prompt points the model at this tool aggressively
/// (the "prefer subagent" rule in the base system prompt) because
/// the token savings are real: a 10-tool-call research chain in
/// the main session burns 10 round-trips of system-prompt +
/// history tokens, while the same chain in a sub-agent burns
/// 10 round-trips of just the sub-agent's tiny system prompt +
/// its own scratch history.
///
/// **Caveats** — the sub-agent's toolset is read-only by design:
/// `file.write`, `notification.show`, `timer.create`, etc. are
/// not available to it. Tasks that need to write to the user's
/// data (e.g. "save this research to a note") must be done by the
/// main agent AFTER the sub-agent returns, using the sub-agent's
/// report as the source of truth.
class SubAgentTool extends ToolBase {
  @override
  String get id => 'subagent';

  @override
  String get name => '子 Agent';

  @override
  String get description =>
      '把与主对话无关的搜集/调研任务交给一个独立的子 AI;'
      '子 agent 在自己的上下文里跑,完成后只把压缩后的报告回给主对话,'
      '保持主对话的整洁与 token 经济。子 agent 可用工具:fetch_web / search / '
      'current_time / location / memory / run_command(只读类调研);'
      '不可用:ask_user / notification / timer / download / file(写) / '
      'google_sheet(写) / mcp__* 等需要用户交互或改用户数据的工具。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'subagent',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': const ['delegate', 'list', 'get', 'cancel'],
              'description':
                  '操作: delegate=启动一个子 agent 并等待结果; '
                  'list=看历史; get=取一份具体报告; cancel=取消运行中的子 agent。',
            },
            // delegate
            'task': {
              'type': 'string',
              'description':
                  'delegate 必填。要子 agent 完成的调研/搜集任务,必须是与主对话上下文无关的独立任务。',
            },
            'want': {
              'type': 'string',
              'description':
                  'delegate 必填。你想从子 agent 那拿回的最终报告形状(例如:'
                  '"一段不超过 200 字的结论 + 3 条事实 + 来源 URL" / '
                  '"列出 A/B/C 三家的定价对比表" / "只返回这一个数字")。'
                  '子 agent 会按这个格式压缩输出,所以越具体越好。',
            },
            'context': {
              'type': 'string',
              'description':
                  'delegate 可选。子 agent 需要的背景信息(从主对话里抽出来的关键事实)。'
                  '**不要把整个主对话都塞进去** — 主对话没必要的细节只会浪费子 agent 的上下文。',
            },
            // get / cancel
            'id': {
              'type': 'string',
              'description': 'get / cancel 必填。子 agent 的任务 id。',
            },
            // list
            'include_terminal': {
              'type': 'boolean',
              'description':
                  'list 时使用:是否包含已结束的任务(completed / failed / cancelled),默认 true。',
              'default': true,
            },
            'max': {
              'type': 'integer',
              'description': 'list 最多返回条数,默认 20。',
              'default': 20,
              'minimum': 1,
              'maximum': 200,
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
    final action = (args['action'] as String? ?? '').trim();
    switch (action) {
      case 'delegate':
        return _delegate(args, services);
      case 'list':
        return _list(args, services);
      case 'get':
        return _get(args, services);
      case 'cancel':
        return _cancel(args, services);
      default:
        throw ToolException(
          'unknown action: $action (expected delegate/list/get/cancel)',
        );
    }
  }

  /// Throws when the tool is called without the chat provider
  /// having wired up a per-session config (the `subagent` tool
  /// needs to know whether to use the cloud or local transport,
  /// and the chat provider is the only place that knows the
  /// user's current settings). The chat provider's dispatcher
  /// in `ChatProvider._onToolCall` resolves this lazily via
  /// [SubAgentTool.runWithConfig] so the tool layer doesn't need
  /// to plumb session state through `ToolService`.
  Future<String> _delegate(Map<String, dynamic> args, ToolService services) {
    throw ToolException(
      'subagent.delegate requires per-session transport config and is '
      'handled by the chat provider',
    );
  }

  String _list(Map<String, dynamic> args, ToolService services) {
    final includeTerminal = args['include_terminal'] as bool? ?? true;
    final max = (args['max'] as num?)?.toInt() ?? 20;
    final all = services.subAgent.tasks;
    final filtered = includeTerminal
        ? all
        : all.where((t) => t.status == SubAgentStatus.running).toList();
    final limited = filtered.length > max ? filtered.sublist(0, max) : filtered;
    return jsonEncode({
      'action': 'list',
      'count': limited.length,
      'include_terminal': includeTerminal,
      'tasks': limited.map((t) => t.toJson()).toList(),
    });
  }

  String _get(Map<String, dynamic> args, ToolService services) {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw ToolException('action=get requires "id"');
    }
    final t = services.subAgent.getById(id);
    if (t == null) {
      return jsonEncode({
        'action': 'get',
        'found': false,
        'id': id,
        'reason': 'no such sub-agent task',
      });
    }
    return jsonEncode({'action': 'get', 'found': true, 'task': t.toJson()});
  }

  String _cancel(Map<String, dynamic> args, ToolService services) {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) {
      throw ToolException('action=cancel requires "id"');
    }
    final t = services.subAgent.getById(id);
    if (t == null) {
      return jsonEncode({
        'action': 'cancel',
        'id': id,
        'ok': false,
        'reason': 'no such sub-agent task',
      });
    }
    services.subAgent.cancel(id);
    return jsonEncode({
      'action': 'cancel',
      'id': id,
      'ok': true,
      'was_running': t.status == SubAgentStatus.running,
    });
  }

  /// Called by `ChatProvider._onToolCall` for the `delegate`
  /// action. The chat provider resolves the per-turn transport
  /// config (cloud vs local) from the user's settings and passes
  /// it in here. The [onProgress] callback lets the chat provider
  /// mirror the sub-agent's progress into the `ToolCall` card so
  /// the user can see "fetch_web → https://…" while the main
  /// turn stays silent.
  Future<String> runDelegate({
    required ToolService services,
    required SubAgentConfig config,
    required String task,
    required String want,
    String context = '',
    SubAgentProgressListener? onProgress,
  }) {
    if (task.trim().isEmpty) {
      throw ToolException('action=delegate requires non-empty "task"');
    }
    if (want.trim().isEmpty) {
      throw ToolException('action=delegate requires non-empty "want"');
    }
    return services.subAgent.run(
      config: config,
      toolService: services,
      task: task,
      want: want,
      context: context,
      onProgress: onProgress,
    );
  }
}
