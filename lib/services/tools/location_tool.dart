import 'tool_base.dart';

class LocationTool extends ToolBase {
  @override
  String get id => 'location';

  @override
  String get name => '位置';

  @override
  String get description =>
      '获取当前位置(经纬度+城市+时区)。手机用 GPS(需授权),电脑/Web 靠 IP。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'location',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': ['get'],
              'description': '固定 get',
            },
            'timeout_ms': {
              'type': 'integer',
              'description': '超时毫秒,默认 10000',
              'default': 10000,
              'minimum': 1000,
              'maximum': 60000,
            },
          },
          'required': const <String>[],
        },
      },
    };
  }
}
