import 'dart:convert';

enum BuiltinTool {
  fetchWeb,
  currentTime,
  askUser,
}

extension BuiltinToolX on BuiltinTool {
  String get id {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return 'fetch_web';
      case BuiltinTool.currentTime:
        return 'current_time';
      case BuiltinTool.askUser:
        return 'ask_user';
    }
  }

  String get name {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return 'Fetch Web';
      case BuiltinTool.currentTime:
        return 'Current Time';
      case BuiltinTool.askUser:
        return 'Ask User';
    }
  }

  String get description {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return '获取指定网址的内容,返回网页的纯文本。';
      case BuiltinTool.currentTime:
        return '获取当前日期与时间,返回本地时间、ISO 8601 与 Unix 时间戳。';
      case BuiltinTool.askUser:
        return '向用户提出一个多选或单选问题,用户作答后把结果回传给模型。';
    }
  }
}

class AgentTool {
  final String id;
  final String name;
  final String description;
  final bool enabled;

  AgentTool({
    required this.id,
    required this.name,
    required this.description,
    this.enabled = true,
  });

  AgentTool copyWith({String? name, String? description, bool? enabled}) {
    return AgentTool(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'enabled': enabled,
      };

  factory AgentTool.fromJson(Map<String, dynamic> json) {
    return AgentTool(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Tool',
      description: json['description'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory AgentTool.fromRawJson(String raw) =>
      AgentTool.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
