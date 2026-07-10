class Task {
  final String id;
  final String title;
  final String? notes;
  final DateTime? due;
  final bool completed;
  final DateTime? completedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Task({
    required this.id,
    required this.title,
    this.notes,
    this.due,
    this.completed = false,
    this.completedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  Task copyWith({
    String? title,
    String? notes,
    DateTime? due,
    bool? completed,
    DateTime? completedAt,
    DateTime? updatedAt,
  }) {
    return Task(
      id: id,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      due: due ?? this.due,
      completed: completed ?? this.completed,
      completedAt: completedAt ?? this.completedAt,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'notes': notes,
    'dueMs': due?.millisecondsSinceEpoch,
    'completed': completed,
    'completedAtMs': completedAt?.millisecondsSinceEpoch,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
    'updatedAtMs': updatedAt.millisecondsSinceEpoch,
  };

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      notes: json['notes'] as String?,
      due: json['dueMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((json['dueMs'] as num).toInt()),
      completed: json['completed'] as bool? ?? false,
      completedAt: json['completedAtMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['completedAtMs'] as num).toInt(),
            ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAtMs'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
