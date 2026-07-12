import 'tool_base.dart';

class NotesTool extends ToolBase {
  @override
  String get id => 'notes';

  @override
  String get name => '笔记';

  @override
  String get description => '管理 Agent Buddy 内置笔记(数据存于本机 Hive,无需系统权限)。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'notes',
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
            'title': {'type': 'string', 'description': 'create/update 时标题'},
            'content': {'type': 'string', 'description': 'create/update 时正文'},
            'keyword': {'type': 'string', 'description': 'list 时可选的标题/内容关键词'},
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
