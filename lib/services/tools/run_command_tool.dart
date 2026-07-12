import 'tool_base.dart';

class RunCommandTool extends ToolBase {
  @override
  String get id => 'run_command';

  @override
  String get name => '命令行执行';

  @override
  String get description =>
      '在电脑上执行命令,返回输出结果和退出码。仅 Windows / macOS / Linux 可用。';

  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'run_command',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'command': {
              'type': 'string',
              'description': '要执行的命令(通过系统 shell 运行)',
            },
            'cwd': {'type': 'string', 'description': '工作目录,可选,默认当前'},
            'timeout_seconds': {
              'type': 'integer',
              'description': '超时秒数,默认 30,超时自动杀掉',
              'default': 30,
              'minimum': 1,
              'maximum': 600,
            },
          },
          'required': ['command'],
        },
      },
    };
  }
}
