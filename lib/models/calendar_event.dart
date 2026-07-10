class CalendarEvent {
  final String id;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String? location;
  final String? notes;
  final int? alarmMinutes;
  final String? calendarId;
  final String? calendarName;

  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    this.end,
    this.allDay = false,
    this.location,
    this.notes,
    this.alarmMinutes,
    this.calendarId,
    this.calendarName,
  });

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? location,
    String? notes,
    int? alarmMinutes,
    String? calendarId,
    String? calendarName,
  }) {
    return CalendarEvent(
      id: id,
      title: title ?? this.title,
      start: start ?? this.start,
      end: end ?? this.end,
      allDay: allDay ?? this.allDay,
      location: location ?? this.location,
      notes: notes ?? this.notes,
      alarmMinutes: alarmMinutes ?? this.alarmMinutes,
      calendarId: calendarId ?? this.calendarId,
      calendarName: calendarName ?? this.calendarName,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'startMs': start.millisecondsSinceEpoch,
    'endMs': end?.millisecondsSinceEpoch,
    'allDay': allDay,
    'location': location,
    'notes': notes,
    'alarmMinutes': alarmMinutes,
    'calendarId': calendarId,
    'calendarName': calendarName,
  };

  factory CalendarEvent.fromJson(Map<String, dynamic> json) {
    return CalendarEvent(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      start: DateTime.fromMillisecondsSinceEpoch(
        (json['startMs'] as num?)?.toInt() ?? 0,
      ),
      end: json['endMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch((json['endMs'] as num).toInt()),
      allDay: json['allDay'] as bool? ?? false,
      location: json['location'] as String?,
      notes: json['notes'] as String?,
      alarmMinutes: (json['alarmMinutes'] as num?)?.toInt(),
      calendarId: json['calendarId'] as String?,
      calendarName: json['calendarName'] as String?,
    );
  }
}
