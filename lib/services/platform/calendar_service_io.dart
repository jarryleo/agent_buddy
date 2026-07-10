import 'package:flutter/services.dart';

import '../../models/calendar_event.dart';
import 'calendar_service.dart';

class CalendarServiceIo implements CalendarService {
  static const MethodChannel _channel = MethodChannel('agent_buddy/calendar');

  @override
  Future<PlatformPermissionStatus> ensurePermission() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'ensurePermission',
      );
      final granted = result?['granted'] as bool? ?? false;
      return granted
          ? PlatformPermissionStatus.granted
          : PlatformPermissionStatus.denied;
    } on MissingPluginException {
      return PlatformPermissionStatus.notSupported;
    } on PlatformException catch (e) {
      if (e.code == 'PERMANENTLY_DENIED') {
        return PlatformPermissionStatus.permanentlyDenied;
      }
      return PlatformPermissionStatus.denied;
    }
  }

  @override
  Future<List<CalendarEvent>> listEvents({
    required DateTime from,
    required DateTime to,
    int max = 50,
  }) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listEvents', {
      'fromMs': from.millisecondsSinceEpoch,
      'toMs': to.millisecondsSinceEpoch,
      'max': max,
    });
    return (raw ?? const [])
        .map((e) => CalendarEvent.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<CalendarEvent?> getEvent(String id) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
      'getEvent',
      {'id': id},
    );
    if (raw == null) return null;
    return CalendarEvent.fromJson(raw.cast<String, dynamic>());
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
    final raw = await _channel
        .invokeMethod<Map<dynamic, dynamic>>('createEvent', {
          'title': title,
          'startMs': start.millisecondsSinceEpoch,
          'endMs': end?.millisecondsSinceEpoch,
          'notes': notes,
          'location': location,
          'alarmMinutes': alarmMinutes,
        });
    return CalendarEvent.fromJson((raw ?? const {}).cast<String, dynamic>());
  }

  @override
  Future<CalendarEvent?> updateEvent(CalendarEvent event) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
      'updateEvent',
      event.toJson(),
    );
    if (raw == null) return null;
    return CalendarEvent.fromJson(raw.cast<String, dynamic>());
  }

  @override
  Future<bool> deleteEvent(String id) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'deleteEvent',
      {'id': id},
    );
    return raw?['ok'] as bool? ?? false;
  }
}
