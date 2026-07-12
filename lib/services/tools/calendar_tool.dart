import 'tool_base.dart';

class CalendarTool extends ToolBase {
  @override
  String get id => 'calendar';

  @override
  String get name => '日历';

  @override
  String get description =>
      '管理手机系统日历(读取 / 创建 / 修改 / 删除 / 列出事件)。'
      '需要日历读取/写入权限。仅 Android / iOS 可用。';

  @override
  bool get isSupportedOnCurrentPlatform => isMobile();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'calendar',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['list', 'get', 'create', 'update', 'delete'],
              'description': '操作类型',
            },
            'id': {'type': 'string', 'description': 'get/update/delete 时必填'},
            'title': {'type': 'string', 'description': 'create/update 时事件标题'},
            'start_ms': {
              'type': 'integer',
              'description': 'create/update 时事件开始时间 (Unix 毫秒)',
            },
            'end_ms': {
              'type': 'integer',
              'description': 'create/update 时事件结束时间 (Unix 毫秒),可选',
            },
            'notes': {'type': 'string', 'description': '事件备注,可选'},
            'location': {'type': 'string', 'description': '事件地点,可选'},
            'alarm_minutes': {'type': 'integer', 'description': '提前多少分钟提醒,可选'},
            'from': {
              'type': 'integer',
              'description': 'list 时窗口起始时间 (Unix 毫秒)',
            },
            'to': {'type': 'integer', 'description': 'list 时窗口结束时间 (Unix 毫秒)'},
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
