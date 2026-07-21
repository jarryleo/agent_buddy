import 'message.dart';
import 'todo_list.dart';

/// A single conversation: a sequence of [ChatMessage]s plus the
/// metadata needed to render the session list and to switch between
/// sessions.
///
/// Persisted to Hive via [ChatSessionAdapter]. The on-disk shape
/// MUST stay backward-compatible: append fields, never repurpose
/// existing ones.
class ChatSession {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<ChatMessage> messages;

  /// Per-session task list the model maintains via the `todo`
  /// tool. Lives on the session so it (a) survives an app restart
  /// — the panel re-renders with the same items on next launch —
  /// and (b) resets when the user switches to a different session.
  /// `TodoList.empty` (the default) means "no todo active on this
  /// session"; see [TodoList] for the lifecycle rules.
  final TodoList todoList;

  const ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messages = const [],
    this.todoList = TodoList.empty,
  });

  /// Title auto-derived from the first user message. Truncated to
  /// keep the session list visually scannable.
  static String deriveTitle(String firstUserMessage) {
    final cleaned = firstUserMessage.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return 'New chat';
    const max = 40;
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max)}…';
  }

  ChatSession copyWith({
    String? title,
    DateTime? updatedAt,
    List<ChatMessage>? messages,
    TodoList? todoList,
  }) {
    return ChatSession(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messages: messages ?? this.messages,
      todoList: todoList ?? this.todoList,
    );
  }
}