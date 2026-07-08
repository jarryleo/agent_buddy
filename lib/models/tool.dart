import 'dart:convert';

enum BuiltinTool {
  fetchWeb,
}

extension BuiltinToolX on BuiltinTool {
  String get id {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return 'fetch_web';
    }
  }

  String get name {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return 'Fetch Web';
    }
  }

  String get description {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return '获取指定网址的内容,返回网页的纯文本。';
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
