import '../../models/calendar_event.dart';
import 'calendar_service.dart';

class CalendarServiceStub implements CalendarService {
  @override
  Future<PlatformPermissionStatus> ensurePermission() async =>
      PlatformPermissionStatus.notSupported;

  @override
  Future<List<CalendarEvent>> listEvents({
    required DateTime from,
    required DateTime to,
    int max = 50,
  }) async {
    throw UnsupportedError(
      'Calendar service is not supported on this platform',
    );
  }

  @override
  Future<CalendarEvent?> getEvent(String id) async {
    throw UnsupportedError(
      'Calendar service is not supported on this platform',
    );
  }

  @override
  Future<CalendarEvent> createEvent({
    required String title,
    required DateTime start,
    DateTime? end,
    String? notes,
    String? location,
    int? alarmMinutes,
  }) async {
    throw UnsupportedError(
      'Calendar service is not supported on this platform',
    );
  }

  @override
  Future<CalendarEvent?> updateEvent(CalendarEvent event) async {
    throw UnsupportedError(
      'Calendar service is not supported on this platform',
    );
  }

  @override
  Future<bool> deleteEvent(String id) async {
    throw UnsupportedError(
      'Calendar service is not supported on this platform',
    );
  }
}
