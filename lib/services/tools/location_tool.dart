import 'tool_base.dart';

class LocationTool extends ToolBase {
  @override
  String get id => 'location';

  @override
  String get name => '位置';

  @override
  String get description =>
      '获取用户当前的大致位置(经纬度 + 行政区划 + 时区)。'
      '移动端用 GPS 定位(需要授权),桌面/Web 用 IP 反查城市与时区。'
      '仅在用户问到天气、附近、本地时区等明确场景时调用,不要主动询问。';

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
              'description': '操作类型,固定 get',
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
