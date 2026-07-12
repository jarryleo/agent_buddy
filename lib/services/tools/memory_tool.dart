import 'tool_base.dart';

class MemoryTool extends ToolBase {
  @override
  String get id => 'memory';

  @override
  String get name => '记忆';

  @override
  String get description =>
      '管理长期记忆。写入时多给 tags 关键词;'
      '查找时用 keywords[] 给多个相关词,命中一个就返回。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'memory',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': [
                'list',
                'search',
                'get',
                'create',
                'update',
                'delete',
                'delete_batch',
              ],
              'description': '操作: list/search/get/create/update/delete/delete_batch',
            },
            'id': {'type': 'string', 'description': 'get/update/delete 时必填'},
            'keywords': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'search 首选:多个关键词任一个匹配内容或 tags 即返回',
            },
            'keyword': {
              'type': 'string',
              'description': 'search 单关键词(等价于 keywords=["…"])',
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'search 时按标签过滤;create/update 时写入标签便于后续查找',
            },
            'content': {
              'type': 'string',
              'description':
                  'create 必填,update 可选。写的时候多提炼关键词',
            },
            'ids': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'delete_batch 时必填,要删的 id 列表',
            },
            'max': {
              'type': 'integer',
              'description': 'list/search 最多返回条数,默认 20',
              'default': 20,
            },
          },
          'required': ['action'],
        },
      },
    };
  }
}
