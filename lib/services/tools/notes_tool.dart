import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

class NotesTool extends ToolBase {
  @override
  String get id => 'notes';
  @override
  String get name => '笔记';
  @override
  String get description => '管理笔记(增删改查),数据存本地,所有平台可用。';
  @override
  String get shortDescription => '本地笔记 CRUD(全平台)';
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

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    const actionList = 'list';
    const actionGet = 'get';
    const actionCreate = 'create';
    const actionUpdate = 'update';
    const actionDelete = 'delete';

    final action = args['action'] as String? ?? '';
    final notes = services.notes;

    switch (action) {
      case actionList:
        final keyword = args['keyword'] as String?;
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final items = notes.list(keyword: keyword, max: max);
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'notes': items.map((n) => n.toJson()).toList(),
        });
      case actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final n = notes.get(id);
        if (n == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({'action': 'get', 'found': true, 'note': n.toJson()});
      case actionCreate:
        final title = args['title'] as String? ?? '';
        final content = args['content'] as String? ?? '';
        if (title.isEmpty) {
          throw ToolException('action=create requires "title"');
        }
        final n = await notes.create(title: title, content: content);
        return jsonEncode({'action': 'create', 'note': n.toJson()});
      case actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final n = await notes.update(
          id: id,
          title: args['title'] as String?,
          content: args['content'] as String?,
        );
        if (n == null) return jsonEncode({'action': 'update', 'found': false});
        return jsonEncode({'action': 'update', 'note': n.toJson()});
      case actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await notes.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      default:
        throw ToolException(
          'unknown action: $action (expected list/get/create/update/delete)',
        );
    }
  }
}
