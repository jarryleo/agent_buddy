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

enum ToolCallStatus { pending, running, success, failed }

class ToolCall {
  final String id;
  final String name;
  final String arguments;
  final ToolCallStatus status;
  final String? result;
  final String? error;
  final DateTime startedAt;
  final DateTime? finishedAt;

  ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.status = ToolCallStatus.pending,
    this.result,
    this.error,
    DateTime? startedAt,
    this.finishedAt,
  }) : startedAt = startedAt ?? DateTime.now();

  bool get isRunning => status == ToolCallStatus.running;
  bool get isDone =>
      status == ToolCallStatus.success || status == ToolCallStatus.failed;
  bool get isSuccess => status == ToolCallStatus.success;
  bool get isFailed => status == ToolCallStatus.failed;

  Duration? get duration => finishedAt?.difference(startedAt);

  ToolCall copyWith({
    ToolCallStatus? status,
    String? result,
    String? error,
    DateTime? finishedAt,
  }) {
    return ToolCall(
      id: id,
      name: name,
      arguments: arguments,
      status: status ?? this.status,
      result: result ?? this.result,
      error: error ?? this.error,
      startedAt: startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'arguments': arguments,
        'status': status.name,
        'result': result,
        'error': error,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
      };

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    return ToolCall(
      id: json['id'] as String,
      name: json['name'] as String,
      arguments: json['arguments'] as String? ?? '',
      status: ToolCallStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ToolCallStatus.pending,
      ),
      result: json['result'] as String?,
      error: json['error'] as String?,
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
    );
  }
}

class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final String thinking;
  final DateTime createdAt;
  final bool streaming;
  final List<ToolCall> toolCalls;

  /// Absolute local file paths for images attached to this message.
  /// Empty for messages without images. The files live in the app's
  /// documents directory and persist across app restarts.
  final List<String> imagePaths;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.thinking = '',
    DateTime? createdAt,
    this.streaming = false,
    this.toolCalls = const [],
    this.imagePaths = const [],
  }) : createdAt = createdAt ?? DateTime.now();

  ChatMessage copyWith({
    MessageRole? role,
    String? content,
    String? thinking,
    bool? streaming,
    List<ToolCall>? toolCalls,
    List<String>? imagePaths,
  }) {
    return ChatMessage(
      id: id,
      role: role ?? this.role,
      content: content ?? this.content,
      thinking: thinking ?? this.thinking,
      createdAt: createdAt,
      streaming: streaming ?? this.streaming,
      toolCalls: toolCalls ?? this.toolCalls,
      imagePaths: imagePaths ?? this.imagePaths,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'content': content,
        'thinking': thinking,
        'createdAt': createdAt.toIso8601String(),
        'toolCalls': toolCalls.map((t) => t.toJson()).toList(),
        'imagePaths': imagePaths,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final tcRaw = json['toolCalls'] as List?;
    final imgRaw = json['imagePaths'] as List?;
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => MessageRole.user,
      ),
      content: json['content'] as String? ?? '',
      thinking: json['thinking'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      toolCalls: tcRaw == null
          ? const []
          : tcRaw
              .map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
              .toList(),
      imagePaths: imgRaw?.cast<String>() ?? const [],
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory ChatMessage.fromRawJson(String raw) =>
      ChatMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
