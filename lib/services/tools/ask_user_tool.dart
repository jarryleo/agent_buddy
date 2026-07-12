import '../tool_service.dart';
import 'tool_base.dart';

class AskUserTool extends ToolBase {
  @override String get id => 'ask_user';
  @override String get name => '询问用户';
  @override String get description =>
      '向用户提问,用户回答后把结果给你。需要用户确认或选择时用。';
  @override bool get isSupportedOnCurrentPlatform => true;

  @override Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'ask_user',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'question': {'type': 'string', 'description': '要问用户的问题'},
            'options': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '给用户选的选项,至少 2 个',
              'minItems': 2,
            },
            'multi_select': {
              'type': 'boolean',
              'description': '允许多选?默认 false(单选)',
              'default': false,
            },
          },
          'required': ['question', 'options'],
        },
      },
    };
  }

  @override
  Future<String> execute(Map<String, dynamic> args, ToolService services) async {
    throw ToolException(
      'ask_user requires UI interaction and is handled by the chat provider',
    );
  }
}
