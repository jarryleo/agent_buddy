import '../../models/calendar_event.dart';

/// Result of a permission request to the host OS.
enum PlatformPermissionStatus {
  granted,
  denied,
  permanentlyDenied,
  notSupported,
}

abstract class CalendarService {
  Future<PlatformPermissionStatus> ensurePermission();
  Future<List<CalendarEvent>> listEvents({
    required DateTime from,
    required DateTime to,
    int max = 50,
  });
  Future<CalendarEvent?> getEvent(String id);
  Future<CalendarEvent> createEvent({
    required String title,
    required DateTime start,
    DateTime? end,
    String? notes,
    String? location,
    int? alarmMinutes,
  });
  Future<CalendarEvent?> updateEvent(CalendarEvent event);
  Future<bool> deleteEvent(String id);
}
