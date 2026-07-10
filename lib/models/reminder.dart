class Reminder {
  final String id;
  final String title;
  final String? notes;
  final DateTime? due;
  final bool completed;
  final DateTime? completedAt;
  final int? priority;

  const Reminder({
    required this.id,
    required this.title,
    this.notes,
    this.due,
    this.completed = false,
    this.completedAt,
    this.priority,
  });

  Reminder copyWith({
    String? title,
    String? notes,
    DateTime? due,
    bool? completed,
    DateTime? completedAt,
    int? priority,
  }) {
    return Reminder(
      id: id,
      title: title ?? this.title,
      notes: notes ?? this.notes,
      due: due ?? this.due,
      completed: completed ?? this.completed,
      completedAt: completedAt ?? this.completedAt,
      priority: priority ?? this.priority,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'notes': notes,
    'dueMs': due?.millisecondsSinceEpoch,
    'completed': completed,
    'completedAtMs': completedAt?.millisecondsSinceEpoch,
    'priority': priority,
  };

  factory Reminder.fromJson(Map<String, dynamic> json) {
    return Reminder(
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
      priority: (json['priority'] as num?)?.toInt(),
    );
  }
}
