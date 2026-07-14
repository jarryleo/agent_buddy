import '../tool_service.dart';
import 'tool_base.dart';

class LoadSkillTool extends ToolBase {
  @override
  String get id => 'load_skill';
  @override
  String get name => '加载技能';
  @override
  String get description => '获取某个技能的完整内容。需要用到某个技能的具体指令时调用此工具获取完整内容';
  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'load_skill',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'skill_name': {
              'type': 'string',
              'description': '要加载的技能名称,必须与上面列表中的名称完全一致',
            },
          },
          'required': ['skill_name'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    throw ToolException(
      'load_skill requires the settings provider and is handled by the chat provider',
    );
  }
}
