import 'dart:convert';

class Role {
  final String id;
  final String name;
  final String avatar;
  final String description;
  final String systemPrompt;
  final bool enabled;

  Role({
    required this.id,
    required this.name,
    this.avatar = '',
    this.description = '',
    this.systemPrompt = '',
    this.enabled = true,
  });

  Role copyWith({
    String? name,
    String? avatar,
    String? description,
    String? systemPrompt,
    bool? enabled,
  }) {
    return Role(
      id: id,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar': avatar,
        'description': description,
        'systemPrompt': systemPrompt,
        'enabled': enabled,
      };

  factory Role.fromJson(Map<String, dynamic> json) {
    return Role(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled',
      avatar: json['avatar'] as String? ?? '',
      description: json['description'] as String? ?? '',
      systemPrompt: json['systemPrompt'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory Role.fromRawJson(String raw) =>
      Role.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
