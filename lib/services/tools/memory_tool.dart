import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

class MemoryTool extends ToolBase {
  @override String get id => 'memory';
  @override String get name => '记忆';
  @override String get description => '管理长期记忆。写入时多给 tags 关键词;查找时用 keywords[] 给多个相关词,命中一个就返回。';
  @override bool get isSupportedOnCurrentPlatform => true;

  @override Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'memory', 'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['list', 'search', 'get', 'create', 'update', 'delete', 'delete_batch'],
              'description': '操作: list/search/get/create/update/delete/delete_batch'},
            'id': {'type': 'string', 'description': 'get/update/delete 时必填'},
            'keywords': {'type': 'array', 'items': {'type': 'string'},
              'description': 'search 首选:多个关键词任一个匹配内容或 tags 即返回'},
            'keyword': {'type': 'string', 'description': 'search 单关键词(等价于 keywords=["…"])'},
            'tags': {'type': 'array', 'items': {'type': 'string'},
              'description': 'search 时按标签过滤;create/update 时写入标签便于后续查找'},
            'content': {'type': 'string', 'description': 'create 必填,update 可选。写的时候多提炼关键词'},
            'ids': {'type': 'array', 'items': {'type': 'string'}, 'description': 'delete_batch 时必填,要删的 id 列表'},
            'max': {'type': 'integer', 'description': 'list/search 最多返回条数,默认 20', 'default': 20},
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
    const actionUpdate = 'update';
    const actionDelete = 'delete';

    final action = args['action'] as String? ?? '';
    final mem = services.memories;

    switch (action) {
      case actionList:
        final max = (args['max'] as num?)?.toInt() ?? 20;
        final items = mem.list(max: max);
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'memories': items.map((m) => m.toJson()).toList(),
        });
      case 'search':
        final rawKeywords = args['keywords'];
        final List<String> keywords;
        if (rawKeywords is List) {
          keywords = rawKeywords.map((e) => e.toString()).toList();
        } else if (rawKeywords is String && rawKeywords.trim().isNotEmpty) {
          keywords = [rawKeywords];
        } else {
          final legacy = args['keyword'] as String? ?? '';
          if (legacy.trim().isNotEmpty) {
            keywords = [legacy];
          } else {
            keywords = const [];
          }
        }
        final tagsRaw = args['tags'];
        final List<String>? tags = tagsRaw is List
            ? tagsRaw.map((e) => e.toString()).toList()
            : null;
        if (keywords.isEmpty && (tags == null || tags.isEmpty)) {
          throw ToolException(
            'action=search requires non-empty "keywords" (array), "keyword" (string), or "tags" (array)',
          );
        }
        final max = (args['max'] as num?)?.toInt() ?? 20;
        final items = mem.list(keywords: keywords, tags: tags, max: max);
        return jsonEncode({
          'action': 'search',
          'keywords': keywords,
          'tags': tags,
          'count': items.length,
          'memories': items.map((m) => m.toJson()).toList(),
        });
      case actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final m = mem.get(id);
        if (m == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({
          'action': 'get',
          'found': true,
          'memory': m.toJson(),
        });
      case actionCreate:
        final content = args['content'] as String? ?? '';
        if (content.trim().isEmpty) {
          throw ToolException('action=create requires "content"');
        }
        final tagsRaw = args['tags'];
        final tags = tagsRaw is List
            ? tagsRaw.map((e) => e.toString()).toList()
            : const <String>[];
        final m = await mem.add(
          content: content,
          source: 'ai',
          tags: tags,
        );
        return jsonEncode({'action': 'create', 'memory': m.toJson()});
      case actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final tagsRaw = args['tags'];
        final List<String>? tags = tagsRaw is List
            ? tagsRaw.map((e) => e.toString()).toList()
            : null;
        final m = await mem.update(
          id: id,
          content: args['content'] as String?,
          tags: tags,
        );
        if (m == null) return jsonEncode({'action': 'update', 'found': false});
        return jsonEncode({'action': 'update', 'memory': m.toJson()});
      case actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await mem.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      case 'delete_batch':
        final ids = (args['ids'] as List?)?.cast<String>() ?? const [];
        if (ids.isEmpty) {
          throw ToolException('action=delete_batch requires non-empty "ids"');
        }
        await mem.deleteMany(ids);
        return jsonEncode({
          'action': 'delete_batch',
          'count': ids.length,
          'ok': true,
        });
      default:
        throw ToolException(
          'unknown action: $action (expected list/search/get/create/update/delete/delete_batch)',
        );
    }
  }
}
