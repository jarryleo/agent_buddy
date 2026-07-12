import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

class RemindersTool extends ToolBase {
  @override String get id => 'reminders';
  @override String get name => '提醒事项';
  @override String get description => '管理提醒和待办(iOS 用 Reminders,Android 用日历)。需要权限。仅手机可用。';
  @override bool get isSupportedOnCurrentPlatform => isMobile();

  @override Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'reminders', 'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['list', 'create', 'complete', 'update', 'delete'],
              'description': '操作: list/create/complete/update/delete'},
            'id': {'type': 'string', 'description': 'complete/update/delete 时必填'},
            'title': {'type': 'string', 'description': 'create/update 的标题'},
            'notes': {'type': 'string', 'description': '备注(可选)'},
            'due_ms': {'type': 'integer', 'description': '截止时间(Unix 毫秒,可选)'},
            'include_completed': {'type': 'boolean', 'description': 'list 是否包含已完成,默认 false', 'default': false},
            'max': {'type': 'integer', 'description': 'list 最多返回条数,默认 50', 'default': 50},
          },
          'required': ['action'],
        },
      },
    };
  }

  @override
  Future<String> execute(Map<String, dynamic> args, ToolService services) async {
    return wrapPlatformExceptions(() => _run(args, services), 'reminders');
  }

  Future<String> _run(Map<String, dynamic> args, ToolService services) async {
    const actionList = 'list';
    const actionCreate = 'create';
    const actionComplete = 'complete';
    const actionUpdate = 'update';
    const actionDelete = 'delete';

    final action = args['action'] as String? ?? '';
    final rem = services.reminders;

    switch (action) {
      case actionList:
        final includeCompleted = args['include_completed'] as bool? ?? false;
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final items = await rem.listReminders(
          includeCompleted: includeCompleted,
          max: max,
        );
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'reminders': items.map((r) => r.toJson()).toList(),
        });
      case actionCreate:
        final title = args['title'] as String? ?? '';
        if (title.isEmpty) {
          throw ToolException('action=create requires "title"');
        }
        final dueMs = (args['due_ms'] as num?)?.toInt();
        final r = await rem.createReminder(
          title: title,
          notes: args['notes'] as String?,
          due: dueMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(dueMs),
        );
        return jsonEncode({'action': 'create', 'reminder': r.toJson()});
      case actionComplete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=complete requires "id"');
        final r = await rem.completeReminder(id);
        if (r == null) {
          return jsonEncode({'action': 'complete', 'found': false});
        }
        return jsonEncode({'action': 'complete', 'reminder': r.toJson()});
      case actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final existing = await rem.listReminders(
          includeCompleted: true,
          max: 200,
        );
        final target = existing.firstWhere(
          (r) => r.id == id,
          orElse: () => throw ToolException('reminder not found: $id'),
        );
        final patched = target.copyWith(
          title: args['title'] as String?,
          notes: args['notes'] as String?,
          due: (args['due_ms'] as num?)?.toInt() == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (args['due_ms'] as num).toInt(),
                ),
        );
        final updated = await rem.updateReminder(patched);
        if (updated == null) {
          return jsonEncode({'action': 'update', 'found': false});
        }
        return jsonEncode({'action': 'update', 'reminder': updated.toJson()});
      case actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await rem.deleteReminder(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      default:
        throw ToolException(
          'unknown action: $action (expected list/create/complete/update/delete)',
        );
    }
  }
}
