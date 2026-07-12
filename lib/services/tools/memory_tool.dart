import 'tool_base.dart';

class MemoryTool extends ToolBase {
  @override
  String get id => 'memory';

  @override
  String get name => '记忆';

  @override
  String get description =>
      '管理 AI 长期记忆:list / search(多关键词 OR 模糊查询,支持 keywords[] + tags 过滤) / '
      'create / get / update / delete / delete_batch。'
      '写入时尽量多列几个 tags 关键词,便于后续模糊查找;'
      '查询时尽量用 keywords[] 一次给多个相关词,以提高召回。';

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
              'description': '操作类型',
            },
            'id': {'type': 'string', 'description': 'get/update/delete 时必填'},
            'keywords': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'search 时首选字段。多个关键词任一命中 content 或 tags 即返回(OR 语义)。',
            },
            'keyword': {
              'type': 'string',
              'description': 'search 时单关键词的兼容写法(等价于 keywords=["…"])',
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'search 时附加过滤:只返回 tags 与此列表有任一交集的记忆;'
                  'create/update 时是写入的关键词标签,便于后续模糊查找。',
            },
            'content': {
              'type': 'string',
              'description':
                  'create 时必填,尽量生成多个关键词,便于读取记忆模糊匹配;'
                  'update 时可选(同时改 content 时填)',
            },
            'ids': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'delete_batch 时必填,记忆 id 列表',
            },
            'max': {
              'type': 'integer',
              'description': 'list/search 时最多返回条数,默认 20',
              'default': 20,
            },
          },
          'required': ['action'],
        },
      },
    };
  }
}
