import 'tool_base.dart';

class AskUserTool extends ToolBase {
  @override
  String get id => 'ask_user';

  @override
  String get name => '询问用户';

  @override
  String get description => '向用户提出一个多选或单选问题,用户作答后把结果回传给模型。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'ask_user',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'question': {'type': 'string', 'description': '要向用户提出的问题'},
            'options': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '用户可选择的选项(至少 2 个)',
              'minItems': 2,
            },
            'multi_select': {
              'type': 'boolean',
              'description': '是否允许多选,默认 false (单选)',
              'default': false,
            },
          },
          'required': ['question', 'options'],
        },
      },
    };
  }
}
