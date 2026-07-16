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

/// Per-assistant-turn performance metrics surfaced in the message
/// bubble footer (right of the timestamp). All fields are optional
/// because they are populated gradually as the stream progresses —
/// before the first token arrives [firstTokenAt] is null; before the
/// stream finishes [lastTokenAt] / token counts may still be 0.
///
/// The model layer ([ChatProvider]) writes these as deltas arrive.
/// The UI reads them via `MessageBubble._buildAssistant`.
class MessageMetrics {
  /// When the request was sent. Used as the "0" anchor for
  /// [firstTokenAt] when computing time-to-first-token.
  final DateTime turnStartedAt;

  /// When the first content or reasoning token arrived. `null`
  /// while the model is still in prefill / connection phase.
  final DateTime? firstTokenAt;

  /// When the last content token arrived. `null` until the
  /// stream emits something, then stamped on every subsequent
  /// `content` event so it always reflects the most recent
  /// delta. Used as the right edge when computing tokens/sec.
  final DateTime? lastTokenAt;

  /// Estimated output tokens (content + reasoning) the model
  /// emitted during this turn. Heuristic estimate — see
  /// `estimateTokens` for the formula.
  final int outputTokens;

  /// Estimated input tokens (system prompts + history + user
  /// message + attached file/image text) sent to the model.
  /// Same heuristic as [outputTokens].
  final int inputTokens;

  const MessageMetrics({
    required this.turnStartedAt,
    this.firstTokenAt,
    this.lastTokenAt,
    this.outputTokens = 0,
    this.inputTokens = 0,
  });

  /// Time-to-first-token (TTFT) measured from [turnStartedAt] to
  /// [firstTokenAt]. Returns `null` if the stream hasn't emitted
  /// its first token yet.
  Duration? get ttft => firstTokenAt?.difference(turnStartedAt);

  /// Decode-stream duration — from [firstTokenAt] to [lastTokenAt].
  /// Returns `null` if either end is unset. Used as the
  /// denominator when computing tokens/sec.
  Duration? get decodeDuration {
    if (firstTokenAt == null || lastTokenAt == null) return null;
    final delta = lastTokenAt!.difference(firstTokenAt!);
    return delta.isNegative ? Duration.zero : delta;
  }

  /// Tokens per second emitted during the decode phase. Returns
  /// `null` if [decodeDuration] is missing or zero. Reported
  /// alongside the output-token count in the bubble footer.
  double? get tokensPerSecond {
    final d = decodeDuration;
    if (d == null || d.inMicroseconds <= 0 || outputTokens <= 0) return null;
    return outputTokens * 1000000.0 / d.inMicroseconds;
  }

  MessageMetrics copyWith({
    DateTime? turnStartedAt,
    DateTime? firstTokenAt,
    DateTime? lastTokenAt,
    int? outputTokens,
    int? inputTokens,
  }) {
    return MessageMetrics(
      turnStartedAt: turnStartedAt ?? this.turnStartedAt,
      firstTokenAt: firstTokenAt ?? this.firstTokenAt,
      lastTokenAt: lastTokenAt ?? this.lastTokenAt,
      outputTokens: outputTokens ?? this.outputTokens,
      inputTokens: inputTokens ?? this.inputTokens,
    );
  }

  Map<String, dynamic> toJson() => {
    'turnStartedAt': turnStartedAt.toIso8601String(),
    if (firstTokenAt != null) 'firstTokenAt': firstTokenAt!.toIso8601String(),
    if (lastTokenAt != null) 'lastTokenAt': lastTokenAt!.toIso8601String(),
    'outputTokens': outputTokens,
    'inputTokens': inputTokens,
  };

  factory MessageMetrics.fromJson(Map<String, dynamic> json) {
    return MessageMetrics(
      turnStartedAt:
          DateTime.tryParse(json['turnStartedAt'] as String? ?? '') ??
          DateTime.now(),
      firstTokenAt: DateTime.tryParse(json['firstTokenAt'] as String? ?? ''),
      lastTokenAt: DateTime.tryParse(json['lastTokenAt'] as String? ?? ''),
      outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
      inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Approximate token count for a piece of text. The codebase
/// has no model-aware tokenizer (and doesn't want to bundle one
/// just to render a footer number), so this uses a simple
/// heuristic that splits the text into three buckets:
///
///   * CJK Unified Ideographs (incl. Extension A): 1 char ≈ 1 token
///     — close enough for Mandarin / Japanese / Korean ranges
///     covered by every tokenizer we care about.
///   * ASCII (single-byte): 4 chars ≈ 1 token — matches
///     tiktoken's average for English / code.
///   * Other (multi-byte Latin / punctuation / emoji): 2 bytes ≈
///     1 token — middle ground for accented Latin, full-width
///     punctuation, etc.
///
/// The result is an `int`; the bubble rounds to one decimal when
/// displaying tps so the user doesn't read "50.7 t/s" as a hard
/// precision claim.
int estimateTokens(String text) {
  if (text.isEmpty) return 0;
  var cjk = 0;
  var ascii = 0;
  var other = 0;
  for (final cu in text.codeUnits) {
    if ((cu >= 0x4E00 && cu <= 0x9FFF) || (cu >= 0x3400 && cu <= 0x4DBF)) {
      cjk++;
    } else if (cu < 0x80) {
      ascii++;
    } else {
      other++;
    }
  }
  return cjk + ((ascii + 3) ~/ 4) + ((other + 1) ~/ 2);
}

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

  /// Per-turn performance metrics (TTFT, tokens/sec, token
  /// counts). Populated by [ChatProvider] while the assistant
  /// turn streams and persisted to disk so the footer survives an
  /// app restart. `null` on user messages and on turns that
  /// never produced any tokens (error before first chunk, etc.).
  final MessageMetrics? metrics;

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
    this.metrics,
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
    MessageMetrics? metrics,
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
      metrics: metrics ?? this.metrics,
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
    if (metrics != null) 'metrics': metrics!.toJson(),
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
      metrics: json['metrics'] == null
          ? null
          : MessageMetrics.fromJson(
              (json['metrics'] as Map).cast<String, dynamic>(),
            ),
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory ChatMessage.fromRawJson(String raw) =>
      ChatMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
