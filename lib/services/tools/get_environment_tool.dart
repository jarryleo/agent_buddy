import 'tool_base.dart';

class GetEnvironmentTool extends ToolBase {
  @override
  String get id => 'get_environment';

  @override
  String get name => '环境信息';

  @override
  String get description =>
      '获取本机环境信息(OS、架构、用户、主目录、shell、内核版本),'
      '供模型在执行 run_command 前判断平台特定命令。仅桌面端 (Windows / macOS / Linux) 可用。';

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
