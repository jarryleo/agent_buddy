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
