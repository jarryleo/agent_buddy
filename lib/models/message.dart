import 'dart:convert';

enum MessageRole { user, assistant, system, tool }

extension MessageRoleX on MessageRole {
  String get label {
    switch (this) {
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.system:
        return 'system';
      case MessageRole.tool:
        return 'tool';
    }
  }
}

class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final String thinking;
  final DateTime createdAt;
  final bool streaming;
  final String? toolName;
  final String? toolResult;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.thinking = '',
    DateTime? createdAt,
    this.streaming = false,
    this.toolName,
    this.toolResult,
  }) : createdAt = createdAt ?? DateTime.now();

  ChatMessage copyWith({
    MessageRole? role,
    String? content,
    String? thinking,
    bool? streaming,
    String? toolName,
    String? toolResult,
  }) {
    return ChatMessage(
      id: id,
      role: role ?? this.role,
      content: content ?? this.content,
      thinking: thinking ?? this.thinking,
      createdAt: createdAt,
      streaming: streaming ?? this.streaming,
      toolName: toolName ?? this.toolName,
      toolResult: toolResult ?? this.toolResult,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'createdAt': createdAt.toIso8601String(),
        'toolName': toolName,
        'toolResult': toolResult,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => MessageRole.user,
      ),
      content: json['content'] as String? ?? '',
      thinking: json['thinking'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      toolName: json['toolName'] as String?,
      toolResult: json['toolResult'] as String?,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory ChatMessage.fromRawJson(String raw) =>
      ChatMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
