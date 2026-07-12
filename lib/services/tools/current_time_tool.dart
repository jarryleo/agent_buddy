import 'tool_base.dart';

class CurrentTimeTool extends ToolBase {
  @override
  String get id => 'current_time';

  @override
  String get name => '当前时间';

  @override
  String get description => '获取当前日期与时间,返回本地时间、ISO 8601 与 Unix 时间戳。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'current_time',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': const <String, dynamic>{},
          'additionalProperties': false,
        },
      },
    };
  }
}
