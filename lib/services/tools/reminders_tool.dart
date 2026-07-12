import 'tool_base.dart';

class RemindersTool extends ToolBase {
  @override
  String get id => 'reminders';

  @override
  String get name => '提醒事项';

  @override
  String get description =>
      '管理提醒事项与待办(iOS: Reminders;Android: 日历全天事件)。'
      '需要提醒/日历写入权限。仅 Android / iOS 可用。';

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
              'description': '操作类型',
            },
            'id': {
              'type': 'string',
              'description': 'complete/update/delete 时必填',
            },
            'title': {'type': 'string', 'description': 'create/update 时标题'},
            'notes': {'type': 'string', 'description': '备注,可选'},
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
