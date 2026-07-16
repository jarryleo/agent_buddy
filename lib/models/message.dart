import 'dart:convert';

import 'download.dart';
import 'file_attachment.dart';

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

  // Populated for the `ask_user` tool: the question, the choice list,
  // and whether the user can pick more than one. We persist these on
  // the tool call itself so the chat history stays self-describing
  // even after the app restarts mid-question.
  final String? question;
  final List<String>? options;
  final bool? multiSelect;

  // Populated for the `download` tool: a live list of
  // [DownloadItem]s in flight under this tool call. The chat
  // provider mutates this list in place as bytes arrive so the
  // message bubble's progress bar can repaint without a full
  // chat-list rebuild. Persisted to disk so the user can come
  // back to a finished download later.
  final List<DownloadItem> downloads;

  /// True when the tool call is parked waiting on a native UI
  /// flow (system file picker, permission dialog, etc.) — the
  /// Dart-side Future is still in flight, but the result won't
  /// arrive until the user interacts with the OS. The chat
  /// bubble uses this to render a "等待用户在系统选择器中操作…"
  /// hint instead of a generic "running…" spinner.
  ///
  /// Not all tools use this; only ones that block on a native
  /// picker / permission prompt do. Persisted so the hint
  /// survives an app restart.
  final bool awaitingUserAction;

  ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.status = ToolCallStatus.pending,
    this.result,
    this.error,
    this.question,
    this.options,
    this.multiSelect,
    this.downloads = const [],
    this.awaitingUserAction = false,
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
    String? question,
    List<String>? options,
    bool? multiSelect,
    List<DownloadItem>? downloads,
    bool? awaitingUserAction,
  }) {
    return ToolCall(
      id: id,
      name: name,
      arguments: arguments,
      status: status ?? this.status,
      result: result ?? this.result,
      error: error ?? this.error,
      question: question ?? this.question,
      options: options ?? this.options,
      multiSelect: multiSelect ?? this.multiSelect,
      downloads: downloads ?? this.downloads,
      awaitingUserAction: awaitingUserAction ?? this.awaitingUserAction,
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
    if (question != null) 'question': question,
    if (options != null) 'options': options,
    if (multiSelect != null) 'multiSelect': multiSelect,
    'downloads': downloads.map((d) => d.toJson()).toList(),
    // Only serialize when true so v1 records (no `awaitingUserAction`
    // key) round-trip identically.
    if (awaitingUserAction) 'awaitingUserAction': true,
  };

  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final rawDownloads = json['downloads'] as List?;
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
      question: json['question'] as String?,
      options: (json['options'] as List?)?.cast<String>(),
      multiSelect: json['multiSelect'] as bool?,
      downloads: rawDownloads == null
          ? const []
          : rawDownloads
                .map((e) => DownloadItem.fromJson(e as Map<String, dynamic>))
                .toList(),
      awaitingUserAction: json['awaitingUserAction'] as bool? ?? false,
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
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
  final List<ChatFileAttachment> fileAttachments;

  /// Set on synthetic "system" messages that the chat provider
  /// appends to the conversation out-of-band (currently used for
  /// the timer-fire reminder fed back to the model). The model
  /// still sees the message in the request list — only the chat
  /// UI hides the bubble. Persisted so a mid-conversation restart
  /// preserves the hidden state.
  final bool hidden;

  ChatMessage({
    required this.id,
    required this.role,
    this.content = '',
    this.thinking = '',
    DateTime? createdAt,
    this.streaming = false,
    this.toolCalls = const [],
    this.imagePaths = const [],
    this.fileAttachments = const [],
    this.hidden = false,
  }) : createdAt = createdAt ?? DateTime.now();

  ChatMessage copyWith({
    MessageRole? role,
    String? content,
    String? thinking,
    bool? streaming,
    List<ToolCall>? toolCalls,
    List<String>? imagePaths,
    List<ChatFileAttachment>? fileAttachments,
    bool? hidden,
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
      fileAttachments: fileAttachments ?? this.fileAttachments,
      hidden: hidden ?? this.hidden,
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
    if (fileAttachments.isNotEmpty)
      'fileAttachments': fileAttachments.map((f) => f.toJson()).toList(),
    // Only serialize when set so v1 records (no `hidden` key)
    // round-trip identically. Default on read is `false`.
    if (hidden) 'hidden': true,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final tcRaw = json['toolCalls'] as List?;
    final imgRaw = json['imagePaths'] as List?;
    final fileRaw = json['fileAttachments'] as List?;
    return ChatMessage(
      id: json['id'] as String,
      role: MessageRole.values.firstWhere(
        (e) => e.name == json['role'],
        orElse: () => MessageRole.user,
      ),
      content: json['content'] as String? ?? '',
      thinking: json['thinking'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      toolCalls: tcRaw == null
          ? const []
          : tcRaw
                .map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
                .toList(),
      imagePaths: imgRaw?.cast<String>() ?? const [],
      fileAttachments: fileRaw == null
          ? const []
          : fileRaw
                .map(
                  (e) => ChatFileAttachment.fromJson(
                    (e as Map).cast<String, dynamic>(),
                  ),
                )
                .toList(),
      hidden: json['hidden'] as bool? ?? false,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory ChatMessage.fromRawJson(String raw) =>
      ChatMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
