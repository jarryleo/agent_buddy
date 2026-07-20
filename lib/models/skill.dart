import 'dart:convert';

class Skill {
  final String id;
  final String name;
  final String description;
  final String content;
  final bool enabled;

  Skill({
    required this.id,
    required this.name,
    this.description = '',
    this.content = '',
    this.enabled = true,
  });

  Skill copyWith({
    String? name,
    String? description,
    String? content,
    bool? enabled,
  }) {
    return Skill(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      enabled: enabled ?? this.enabled,
    );
  }

  /// Stable id prefix used for every skill that ships with the app.
  /// The UI uses this to hide the delete button (built-ins can't be
  /// removed) and `SettingsProvider.load()` uses it to back-fill any
  /// new built-ins on upgrade.
  static const String builtinIdPrefix = 'builtin:';

  bool get isBuiltin => id.startsWith(builtinIdPrefix);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'content': content,
    'enabled': enabled,
  };

  factory Skill.fromJson(Map<String, dynamic> json) {
    return Skill(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Skill',
      description: json['description'] as String? ?? '',
      content: json['content'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory Skill.fromRawJson(String raw) =>
      Skill.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Static definition of a skill that ships with the app.
///
/// Mirrors the `ToolBase` pattern: a stable id, a display name, a
/// short description shown in the system prompt, and the full
/// content the AI sees when it calls `load_skill`. The id always
/// carries the `builtin:` prefix so [Skill.isBuiltin] is reliable.
class BuiltinSkill {
  const BuiltinSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.content,
  });

  final String id;
  final String name;
  final String description;
  final String content;

  Skill toSkill() => Skill(
    id: id,
    name: name,
    description: description,
    content: content,
    enabled: true,
  );
}

/// Registry of every skill that ships with the app. Ordered — the
/// first entry is the most general / commonly useful.
///
/// **No `tool_usage` skill anymore.** Per-tool best-practices used
/// to live here (~1.5K tokens the model loaded on first touch via
/// `load_skill`), but every section of that document is now part
/// of the matching tool's [ToolBase.compactSchemaForModel] — the
/// model pulls it down with `load_tool(name)` and it's already in
/// scope when the function call fires. Saves one round-trip +
/// roughly halves the per-tool token cost.
class BuiltinSkills {
  BuiltinSkills._();

  static const List<BuiltinSkill> all = [
    BuiltinSkill(
      id: '${Skill.builtinIdPrefix}news',
      name: '查询新闻技能',
      description: '用户想知道新闻时,可以使用这个技能',
      content: '''
通过 fetch_web 工具同时抓取这些网址以获取最新新闻:
https://news.cctv.com/
http://www.people.com.cn/
http://www.xinhuanet.com/
https://www.163.com/news/
http://www.sina.com.cn/

抓取后合并去重,按主题(国内 / 国际 / 社会 / 财经 / 科技 / 体育 / 娱乐)分类整理后输出。每条新闻给出标题、来源、时间和 1 句话摘要。''',
    ),
    BuiltinSkill(
      id: '${Skill.builtinIdPrefix}weather',
      name: '查询天气',
      description: '当用户想获知天气时调用',
      content: '''
先使用 location 工具获取用户所在城市(已知城市可跳过),然后把城市名转成拼音(例如"北京" → "beijing","上海" → "shanghai"),用 fetch_web 工具抓取:
https://www.tianqi.com/<城市拼音>/

把抓取到的当日天气、温度范围、风力、空气质量,以及未来 2~3 天趋势整理成简短的天气报告输出。''',
    ),
  ];

  /// Map by id for O(1) lookups (e.g. when deciding whether an
  /// unknown id in the persisted list is a built-in we should
  /// re-seed).
  static final Map<String, BuiltinSkill> _byId = {for (final s in all) s.id: s};

  static BuiltinSkill? byId(String id) => _byId[id];
}
