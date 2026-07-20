import '../tool_service.dart';
import 'tool_base.dart';

class AskUserTool extends ToolBase {
  @override
  String get id => 'ask_user';
  @override
  String get name => '询问用户';
  @override
  String get description => '向用户提问,用户回答后把结果给你。需要用户确认或选择时用。';
  @override
  String get shortDescription => '向用户提问(选项式)';
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
  String get compactSchemaForModel => '''
参数:
- question (string, 必填): 给用户的问题(简短,一句话)
- options (string[], 必填, 至少 2 个): 互斥/可选的选项,2~6 个最好
- multi_select (bool, 默认 false): true=多选(选 N 个);false=单选

返回: 用户选中的选项字符串(单选)或 [字符串, ...](多选)。

最佳实践:
- 给 2~6 个互斥选项,不要列 10 个以上 —— 用户会懵。
- 选项文本不要太长(< 30 字/项)。
- 只有确实需要用户决策时才用,别没事找事问。
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
