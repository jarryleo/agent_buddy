import 'tool_base.dart';

class GetEnvironmentTool extends ToolBase {
  @override
  String get id => 'get_environment';

  @override
  String get name => '环境信息';

  @override
  String get description =>
      '查看本机系统信息(系统类型、架构、用户名等)。执行命令前先看看环境。仅桌面端可用。';

  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'get_environment',
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
