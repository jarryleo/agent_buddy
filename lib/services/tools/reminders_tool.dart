import 'tool_base.dart';

class RemindersTool extends ToolBase {
  @override
  String get id => 'reminders';

  @override
  String get name => '提醒事项';

  @override
  String get description =>
      '管理提醒和待办(iOS 用 Reminders,Android 用日历)。'
      '需要权限。仅手机可用。';

  @override
  bool get isSupportedOnCurrentPlatform => isMobile();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'reminders',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['list', 'create', 'complete', 'update', 'delete'],
              'description': '操作: list/create/complete/update/delete',
            },
            'id': {
              'type': 'string',
              'description': 'complete/update/delete 时必填',
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
