import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

/// `timer` tool — AI-driven reminder queue. The model uses this to
/// schedule a callback to itself at a future time, list / update /
/// delete its own pending reminders, and (via the
/// [NotificationService] bridge in [TimerService]) surface a
/// notification to the user when a timer fires.
///
/// **Only effective while the app is running.** There is no
/// persistence to disk and no native background workers; the
/// scheduler lives in `TimerService` and is reset on app kill.
/// Models should make this constraint explicit to the user when
/// scheduling long-horizon reminders.
class TimerTool extends ToolBase {
  @override
  String get id => 'timer';
  @override
  String get name => '计时器';
  @override
  String get description => '在指定时间后回调自己(可以同时触发系统通知)。可对计时任务进行增删改查。仅在程序运行时有效。';
  @override
  String get shortDescription => '定时回调自己(仅运行时有效)';
  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  String get compactSchemaForModel => '''
参数:
- action (string, 必填): create | list | update | cancel | delete | get
- create / update:
  - label (string, 必填): 简短标签,通知/列表里都显示
  - delay_seconds (int) 或 fire_at_ms (int): 二选一
  - prompt (string): 到点时合成 user 消息的内容,模型就是看着这个 prompt 决定做什么
  - action_hint (string, 可选): 提示模型到点该调什么(如"调用 notification 通知用户…")
- list: include_terminal (bool, 默认 false);max
- get / cancel / delete: id
- update 字段可单独传

返回:
- create: {action, task:{id, label, fire_at_ms, status:pending}}
- list: {action, count, tasks:[...]}
- cancel: {action, id, cancelled:true}

约束 + 最佳实践:
- **仅在程序运行时有效**,app 退出/被杀则丢失 → 用户说"X 分钟后提醒我 Y"时,长时段务必先告知用户。
- 触发时:ChatProvider 收到 onTimerFired → 注入合成 user 消息 → 模型新轮 → 由模型调 `notification.show` 把提醒正式发给用户(避免僵硬预设)。
- prompt/action_hint 写好,模型到点才知道做什么;否则会乱答。
''';

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'timer',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': const ['list', 'get', 'create', 'update', 'delete'],
              'description': '操作: list/get/create/update/delete',
            },
            // create
            'label': {
              'type': 'string',
              'description': 'create 必填,update 可选。简短标题,会作为通知的标题。',
            },
            'delay_seconds': {
              'type': 'integer',
              'description':
                  'create/update 时使用:多少秒后触发(优先于 fire_at_iso)。必须为正整数。',
              'minimum': 0,
            },
            'fire_at_iso': {
              'type': 'string',
              'description': 'create/update 时使用:绝对触发时间(ISO 8601 本地时区)。',
            },
            'prompt': {
              'type': 'string',
              'description':
                  'create/update 可选:提醒消息正文,触发时会作为系统通知的 body,也会回传给 AI。',
            },
            'action_hint': {
              'type': 'string',
              'description':
                  'create/update 可选:触发时给 AI 的提示,告诉它该怎么处理这次回调(例如"调用 notification 通知用户喝水")。',
            },
            // get/update/delete
            'id': {'type': 'string', 'description': 'get/update/delete 必填'},
            // list
            'include_terminal': {
              'type': 'boolean',
              'description': 'list 时使用:是否包含已触发/已取消的记录,默认 false',
            },
            'max': {
              'type': 'integer',
              'description': 'list 最多返回条数,默认 50',
              'default': 50,
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
    final action = args['action'] as String? ?? '';
    final timers = services.timers;

    switch (action) {
      case 'list':
        final includeTerminal = args['include_terminal'] as bool? ?? false;
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final all = timers.tasks;
        final filtered = includeTerminal
            ? all
            : all.where((t) => t.isPending).toList();
        final limited = filtered.length > max
            ? filtered.sublist(0, max)
            : filtered;
        return jsonEncode({
          'action': 'list',
          'count': limited.length,
          'include_terminal': includeTerminal,
          'timers': limited.map((t) => t.toJson()).toList(),
        });

      case 'get':
        final id = (args['id'] as String? ?? '').trim();
        if (id.isEmpty) {
          throw ToolException('action=get requires "id"');
        }
        final t = timers.getById(id);
        if (t == null) {
          return jsonEncode({'action': 'get', 'found': false, 'id': id});
        }
        return jsonEncode({
          'action': 'get',
          'found': true,
          'timer': t.toJson(),
        });

      case 'create':
        final label = (args['label'] as String? ?? '').trim();
        if (label.isEmpty) {
          throw ToolException('action=create requires non-empty "label"');
        }
        final delay = (args['delay_seconds'] as num?)?.toInt();
        final fireAtRaw = args['fire_at_iso'] as String?;
        DateTime? fireAt;
        if (fireAtRaw != null && fireAtRaw.isNotEmpty) {
          final parsed = DateTime.tryParse(fireAtRaw);
          if (parsed == null) {
            throw ToolException(
              'action=create: invalid fire_at_iso "$fireAtRaw" (expected ISO 8601 like 2025-01-02T03:04:05)',
            );
          }
          fireAt = parsed;
        }
        if (delay == null && fireAt == null) {
          throw ToolException(
            'action=create requires "delay_seconds" or "fire_at_iso"',
          );
        }
        if (delay != null && delay < 0) {
          throw ToolException('action=create: delay_seconds must be >= 0');
        }
        final prompt = (args['prompt'] as String? ?? '').trim();
        final actionHint = (args['action_hint'] as String? ?? '').trim();
        final created = await timers.create(
          label: label,
          fireAt: fireAt,
          delay: delay != null ? Duration(seconds: delay) : null,
          prompt: prompt,
          actionHint: actionHint.isEmpty ? null : actionHint,
          source: 'ai',
        );
        return jsonEncode({'action': 'create', 'timer': created.toJson()});

      case 'update':
        final id = (args['id'] as String? ?? '').trim();
        if (id.isEmpty) {
          throw ToolException('action=update requires "id"');
        }
        final delay = (args['delay_seconds'] as num?)?.toInt();
        final fireAtRaw = args['fire_at_iso'] as String?;
        DateTime? fireAt;
        if (fireAtRaw != null && fireAtRaw.isNotEmpty) {
          final parsed = DateTime.tryParse(fireAtRaw);
          if (parsed == null) {
            throw ToolException(
              'action=update: invalid fire_at_iso "$fireAtRaw"',
            );
          }
          fireAt = parsed;
        }
        if (delay != null && delay < 0) {
          throw ToolException('action=update: delay_seconds must be >= 0');
        }
        final prompt = args['prompt'] as String?;
        final actionHint = args['action_hint'] as String?;
        final updated = await timers.update(
          id: id,
          label: args['label'] as String?,
          fireAt: fireAt,
          delay: delay != null ? Duration(seconds: delay) : null,
          prompt: prompt,
          actionHint: actionHint,
        );
        if (updated == null) {
          return jsonEncode({
            'action': 'update',
            'found': false,
            'id': id,
            'reason': 'no such pending task',
          });
        }
        return jsonEncode({'action': 'update', 'timer': updated.toJson()});

      case 'delete':
        final id = (args['id'] as String? ?? '').trim();
        if (id.isEmpty) {
          throw ToolException('action=delete requires "id"');
        }
        final ok = await timers.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});

      default:
        throw ToolException(
          'unknown action: $action (expected list/get/create/update/delete)',
        );
    }
  }
}
