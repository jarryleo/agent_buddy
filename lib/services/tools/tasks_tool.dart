import 'tool_base.dart';

class TasksTool extends ToolBase {
  @override
  String get id => 'tasks';

  @override
  String get name => '任务';

  @override
  String get description =>
      '管理 Agent Buddy 内置任务清单(数据存于本机 Hive,无需系统权限)。'
      'Android 上作为"待办"的回退通路。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'tasks',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['list', 'get', 'create', 'complete', 'update', 'delete'],
              'description': '操作类型',
            },
            'id': {
              'type': 'string',
              'description': 'get/complete/update/delete 时必填',
            },
            'title': {'type': 'string', 'description': 'create/update 时标题'},
            'notes': {'type': 'string', 'description': 'create/update 时备注,可选'},
            'due_ms': {'type': 'integer', 'description': '截止时间 (Unix 毫秒),可选'},
            'include_completed': {
              'type': 'boolean',
              'description': 'list 时是否包含已完成,默认 false',
              'default': false,
            },
            'max': {
              'type': 'integer',
              'description': 'list 时最多返回条数,默认 50',
              'default': 50,
            },
          },
          'required': ['action'],
        },
      },
    };
  }
}
