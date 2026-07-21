import '../tool_service.dart';
import 'tool_base.dart';

class AskUserTool extends ToolBase {
  @override
  String get id => 'ask_user';
  @override
  String get name => '询问用户';
  @override
  String get description => '一次向用户询问一个或多个问题,用户可选择选项或手动输入答案。';
  @override
  String get shortDescription => '向用户提问(支持多问题、选项或手输)';
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
            'questions': {
              'type': 'array',
              'description': '按顺序询问的问题,用户回答一个后才显示下一个',
              'minItems': 1,
              'maxItems': 8,
              'items': {
                'type': 'object',
                'properties': {
                  'question': {'type': 'string', 'description': '问题内容'},
                  'options': {
                    'type': 'array',
                    'items': {'type': 'string'},
                    'description': '可选答案;可省略以只让用户手动输入',
                  },
                  'multi_select': {
                    'type': 'boolean',
                    'description': '是否允许多选,默认 false',
                    'default': false,
                  },
                },
                'required': ['question'],
              },
            },
          },
          'required': ['questions'],
        },
      },
    };
  }

  @override
  String get compactSchemaForModel => '''
参数:
- questions (array, 必填, 1~8 项): 按顺序询问的问题。
  - question (string, 必填): 简短问题。
  - options (string[], 可选): 供用户选择的答案;即使提供选项,用户也能手动输入其他答案。
  - multi_select (bool, 默认 false): true=可选多个选项并附加手动答案;false=单选或手动输入。

交互: 界面一次只展示一个问题,用户回答后自动展示下一个。
返回: {"answers":[{"question":"...","answer":"..."}, ...]};多选答案为字符串数组。只有一个问题时兼容返回 {"selection": ...}。

最佳实践:
- 有多个相关问题时放在同一次调用里,不要连续调用多次 ask_user。
- 每题给 2~6 个简短选项;开放题可省略 options。
- 一次不要超过 5 个问题,只有确实需要用户决策或补充信息时才用。
''';

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    throw ToolException(
      'ask_user requires UI interaction and is handled by the chat provider',
    );
  }
}
