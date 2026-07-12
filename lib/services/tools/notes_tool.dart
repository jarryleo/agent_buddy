import 'tool_base.dart';

class NotesTool extends ToolBase {
  @override
  String get id => 'notes';

  @override
  String get name => '笔记';

  @override
  String get description => '管理笔记(增删改查),数据存本地,所有平台可用。';

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
              'description': '操作: list/get/create/update/delete',
            },
            'id': {'type': 'string', 'description': 'get/update/delete 时必填'},
            'title': {'type': 'string', 'description': 'create/update 的标题'},
            'content': {'type': 'string', 'description': 'create/update 的正文'},
            'keyword': {'type': 'string', 'description': 'list 时按关键词筛选'},
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
