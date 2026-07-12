import 'tool_base.dart';

class TasksTool extends ToolBase {
  @override
  String get id => 'tasks';

  @override
  String get name => '任务';

  @override
  String get description =>
      '管理待办清单(增删改查/标记完成),数据存本地,所有平台可用。';

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
              'description': '操作: list/get/create/complete/update/delete',
            },
            'id': {
              'type': 'string',
              'description': 'get/complete/update/delete 时必填',
            },
            'title': {'type': 'string', 'description': 'create/update 的标题'},
            'notes': {'type': 'string', 'description': '备注(可选)'},
            'due_ms': {'type': 'integer', 'description': '截止时间(Unix 毫秒,可选)'},
            'include_completed': {
              'type': 'boolean',
              'description': 'list 是否包含已完成,默认 false',
              'default': false,
            },
            'max': {
              'type': 'integer',
              'description': 'list 最多返回条数,默认 50',
              'default': 50,
            },
          },
          'required': ['action'],
        },
      },
    };
  }
}
