import 'package:flutter/foundation.dart';

enum TodoItemStatus { pending, done }

extension TodoItemStatusX on TodoItemStatus {
  String get wireName {
    switch (this) {
      case TodoItemStatus.pending:
        return 'pending';
      case TodoItemStatus.done:
        return 'done';
    }
  }

  static TodoItemStatus fromWire(String? raw) {
    switch (raw) {
      case 'done':
        return TodoItemStatus.done;
      case 'pending':
      default:
        return TodoItemStatus.pending;
    }
  }
}

/// A single item in a [TodoList] the model is working through.
///
/// Lives **per-conversation** — see [TodoList] for the lifetime
/// rules. The id is opaque to the model (it's a UUIDv4 with a
/// `td_` prefix); the model carries it across calls so it can
/// target individual items via `todo(action='complete', id=...)`
/// or `todo(action='update', id=...)` without re-listing the
/// whole list.
@immutable
class TodoItem {
  /// Stable id (`td_<uuid>`). The model passes this back in
  /// `complete` / `update` / `remove` calls so we don't need a
  /// matching-by-content layer.
  final String id;

  /// One-line description, the visible body in the panel. Always
  /// non-empty after the tool's validation gate; the model is
  /// free to put tool args or a human-friendly phrasing here.
  final String content;

  /// Optional secondary line. Used by the panel as a smaller,
  /// dimmer caption under [content] (e.g. "search via fetch_web
  /// + memory"). The model can leave it null.
  final String? detail;

  /// Pending → not yet completed; done → model has marked it.
  final TodoItemStatus status;

  /// 0-indexed position in the list. Lower = earlier. The model
  /// doesn't drive this directly — the tool maintains ordering
  /// via the [TodoList.add] API which appends.
  final int order;

  final DateTime createdAt;
  final DateTime? completedAt;

  const TodoItem({
    required this.id,
    required this.content,
    this.detail,
    this.status = TodoItemStatus.pending,
    required this.order,
    required this.createdAt,
    this.completedAt,
  });

  bool get isDone => status == TodoItemStatus.done;

  TodoItem copyWith({
    String? content,
    String? detail,
    TodoItemStatus? status,
    int? order,
    DateTime? completedAt,
    bool clearDetail = false,
    bool clearCompletedAt = false,
  }) {
    return TodoItem(
      id: id,
      content: content ?? this.content,
      detail: clearDetail ? null : (detail ?? this.detail),
      status: status ?? this.status,
      order: order ?? this.order,
      createdAt: createdAt,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    if (detail != null && detail!.isNotEmpty) 'detail': detail,
    'status': status.wireName,
    'order': order,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
    if (completedAt != null)
      'completedAtMs': completedAt!.millisecondsSinceEpoch,
  };

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    final completedAtMs = json['completedAtMs'];
    return TodoItem(
      id: json['id'] as String,
      content: json['content'] as String? ?? '',
      detail: json['detail'] as String?,
      status: TodoItemStatusX.fromWire(json['status'] as String?),
      order: (json['order'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAtMs'] as num?)?.toInt() ?? 0,
      ),
      completedAt: completedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((completedAtMs as num).toInt()),
    );
  }
}

/// A per-conversation todo list that the model uses to plan a
/// long task and the chat provider uses to drive the supervision
/// loop. Owned by the active [ChatSession] (not a global); when
/// the user switches sessions, the panel switches with it, and
/// when a brand-new session starts, the list starts empty.
///
/// Lifecycle rules (enforced by the chat provider, not by the
/// tool itself):
///
///   * The list becomes "active" the first time the model calls
///     `todo(action='add', ...)`. The chat panel above the input
///     shows it.
///   * The list is "complete" once every item is `done`. The
///     panel auto-hides on the next render (the underlying
///     instance is kept around until the next `clear` /
///     `create` / session switch, so a render-during-the-same-
///     turn doesn't flicker).
///   * The user can manually `clear` the list at any time via
///     the panel's dismiss button — this also cancels any
///     pending supervision prompt for this turn.
///   * When the user sends a brand-new message, the chat
///     provider re-arms the supervision loop (any previous
///     "user stopped" flag is reset) and the existing list
///     stays — the model is expected to call `todo.clear` then
///     rebuild if it sees a different task. If the user instead
///     hits "放弃任务 / abandon", the list is dropped entirely.
@immutable
class TodoList {
  /// The list's display title, set on the first `create` call
  /// and (optionally) updated on subsequent calls. `null` until
  /// the first `create` lands; the panel shows a generic
  /// "任务清单" / "Task list" header in that case.
  final String? title;

  /// When the first item was added (set by the tool). `null`
  /// until the first add so the panel doesn't render an empty
  /// zero-state vs. a real "0/N" progress state — those are
  /// different UX moments.
  final DateTime? createdAt;

  /// Monotonic counter, bumped on every mutation. The chat
  /// provider uses it to detect "list changed during the
  /// supervision grace window" so it doesn't fire a resume
  /// prompt while the model is still mid-edit.
  final int revision;

  final List<TodoItem> items;

  const TodoList({
    this.title,
    this.createdAt,
    this.revision = 0,
    this.items = const [],
  });

  /// An empty list — used by the chat provider to mean "no todo
  /// currently active on this session".
  static const TodoList empty = TodoList();

  /// True when there's nothing to show / supervise.
  bool get isEmpty => items.isEmpty;

  bool get isNotEmpty => items.isEmpty == false;

  int get totalCount => items.length;

  int get completedCount =>
      items.where((i) => i.status == TodoItemStatus.done).length;

  /// True when every item is `done` (or the list is empty —
  /// which technically counts as "complete" so the panel can
  /// hide without special-casing). The chat provider uses this
  /// to decide whether to schedule a supervision resume.
  bool get allDone => items.isEmpty || items.every((i) => i.isDone);

  /// Subset of items that the model still owes work on. Empty
  /// iff [allDone].
  List<TodoItem> get pendingItems =>
      items.where((i) => i.status == TodoItemStatus.pending).toList();

  TodoItem? byId(String id) {
    for (final it in items) {
      if (it.id == id) return it;
    }
    return null;
  }

  TodoList copyWith({
    String? title,
    DateTime? createdAt,
    int? revision,
    List<TodoItem>? items,
    bool clearTitle = false,
    bool clearCreatedAt = false,
  }) {
    return TodoList(
      title: clearTitle ? null : (title ?? this.title),
      createdAt: clearCreatedAt ? null : (createdAt ?? this.createdAt),
      revision: revision ?? this.revision,
      items: items ?? this.items,
    );
  }

  Map<String, dynamic> toJson() => {
    if (title != null) 'title': title,
    if (createdAt != null) 'createdAtMs': createdAt!.millisecondsSinceEpoch,
    'revision': revision,
    'items': items.map((i) => i.toJson()).toList(),
  };

  factory TodoList.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List? ?? const [];
    return TodoList(
      title: json['title'] as String?,
      createdAt: json['createdAtMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['createdAtMs'] as num).toInt(),
            ),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      items: rawItems
          .map((e) => TodoItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }
}
