import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

class TasksTool extends ToolBase {
  @override String get id => 'tasks';
  @override String get name => '任务';
  @override String get description => '管理待办清单(增删改查/标记完成),数据存本地,所有平台可用。';
  @override bool get isSupportedOnCurrentPlatform => true;

  @override Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'tasks', 'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['list', 'get', 'create', 'complete', 'update', 'delete'],
              'description': '操作: list/get/create/complete/update/delete'},
            'id': {'type': 'string', 'description': 'get/complete/update/delete 时必填'},
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
    const actionList = 'list';
    const actionGet = 'get';
    const actionCreate = 'create';
    const actionComplete = 'complete';
    const actionUpdate = 'update';
    const actionDelete = 'delete';

    final action = args['action'] as String? ?? '';
    final tasks = services.tasks;

    switch (action) {
      case actionList:
        final includeCompleted = args['include_completed'] as bool? ?? false;
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final items = tasks.list(includeCompleted: includeCompleted, max: max);
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'tasks': items.map((t) => t.toJson()).toList(),
        });
      case actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final t = tasks.get(id);
        if (t == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({'action': 'get', 'found': true, 'task': t.toJson()});
      case actionCreate:
        final title = args['title'] as String? ?? '';
        if (title.isEmpty) {
          throw ToolException('action=create requires "title"');
        }
        final dueMs = (args['due_ms'] as num?)?.toInt();
        final t = await tasks.create(
          title: title,
          notes: args['notes'] as String?,
          due: dueMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(dueMs),
        );
        return jsonEncode({'action': 'create', 'task': t.toJson()});
      case actionComplete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=complete requires "id"');
        final t = await tasks.complete(id);
        if (t == null) {
          return jsonEncode({'action': 'complete', 'found': false});
        }
        return jsonEncode({'action': 'complete', 'task': t.toJson()});
      case actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final dueMs = (args['due_ms'] as num?)?.toInt();
        final t = await tasks.update(
          id: id,
          title: args['title'] as String?,
          notes: args['notes'] as String?,
          due: dueMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(dueMs),
        );
        if (t == null) return jsonEncode({'action': 'update', 'found': false});
        return jsonEncode({'action': 'update', 'task': t.toJson()});
      case actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await tasks.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      default:
        throw ToolException(
          'unknown action: $action (expected list/get/create/complete/update/delete)',
        );
    }
  }
}
