import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

class CalendarTool extends ToolBase {
  @override
  String get id => 'calendar';
  @override
  String get name => '日历';
  @override
  String get description => '管理手机日历(增删改查)。需要日历权限。仅 Android / iOS 可用。';
  @override
  String get shortDescription => '手机日历 CRUD(需日历权限)';
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
              'description': '操作: list/get/create/update/delete',
            },
            'id': {'type': 'string', 'description': 'get/update/delete 时必填'},
            'title': {'type': 'string', 'description': 'create/update 的事件标题'},
            'start_ms': {
              'type': 'integer',
              'description': 'create/update 开始时间(Unix 毫秒)',
            },
            'end_ms': {
              'type': 'integer',
              'description': 'create/update 结束时间(Unix 毫秒,可选)',
            },
            'notes': {'type': 'string', 'description': '备注(可选)'},
            'location': {'type': 'string', 'description': '地点(可选)'},
            'alarm_minutes': {'type': 'integer', 'description': '提前多少分钟提醒(可选)'},
            'from': {'type': 'integer', 'description': 'list 查询窗口起始(Unix 毫秒)'},
            'to': {'type': 'integer', 'description': 'list 查询窗口结束(Unix 毫秒)'},
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
    return wrapPlatformExceptions(() => _run(args, services), 'calendar');
  }

  Future<String> _run(Map<String, dynamic> args, ToolService services) async {
    const actionList = 'list';
    const actionGet = 'get';
    const actionCreate = 'create';
    const actionUpdate = 'update';
    const actionDelete = 'delete';

    final action = args['action'] as String? ?? '';
    final cal = services.calendar;

    switch (action) {
      case actionList:
        final fromMs = (args['from'] as num?)?.toInt();
        final toMs = (args['to'] as num?)?.toInt();
        if (fromMs == null || toMs == null) {
          throw ToolException('action=list requires "from" and "to" (ms)');
        }
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final events = await cal.listEvents(
          from: DateTime.fromMillisecondsSinceEpoch(fromMs),
          to: DateTime.fromMillisecondsSinceEpoch(toMs),
          max: max,
        );
        return jsonEncode({
          'action': 'list',
          'count': events.length,
          'events': events.map((e) => e.toJson()).toList(),
        });
      case actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final ev = await cal.getEvent(id);
        if (ev == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({
          'action': 'get',
          'found': true,
          'event': ev.toJson(),
        });
      case actionCreate:
        final title = args['title'] as String? ?? '';
        final startMs = (args['start_ms'] as num?)?.toInt();
        if (title.isEmpty || startMs == null) {
          throw ToolException('action=create requires "title" and "start_ms"');
        }
        final ev = await cal.createEvent(
          title: title,
          start: DateTime.fromMillisecondsSinceEpoch(startMs),
          end: (args['end_ms'] as num?)?.toInt() == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (args['end_ms'] as num).toInt(),
                ),
          notes: args['notes'] as String?,
          location: args['location'] as String?,
          alarmMinutes: (args['alarm_minutes'] as num?)?.toInt(),
        );
        return jsonEncode({'action': 'create', 'event': ev.toJson()});
      case actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final existing = await cal.getEvent(id);
        if (existing == null) {
          return jsonEncode({'action': 'update', 'found': false});
        }
        final patched = existing.copyWith(
          title: args['title'] as String?,
          start: (args['start_ms'] as num?)?.toInt() == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (args['start_ms'] as num).toInt(),
                ),
          end: (args['end_ms'] as num?)?.toInt() == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (args['end_ms'] as num).toInt(),
                ),
          notes: args['notes'] as String?,
          location: args['location'] as String?,
          alarmMinutes: (args['alarm_minutes'] as num?)?.toInt(),
        );
        final updated = await cal.updateEvent(patched);
        if (updated == null) {
          return jsonEncode({'action': 'update', 'found': false});
        }
        return jsonEncode({'action': 'update', 'event': updated.toJson()});
      case actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await cal.deleteEvent(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      default:
        throw ToolException(
          'unknown action: $action (expected list/get/create/update/delete)',
        );
    }
  }
}
