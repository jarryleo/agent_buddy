import 'package:flutter/services.dart';

import '../../models/reminder.dart';
import 'calendar_service.dart' show PlatformPermissionStatus;
import 'reminders_service.dart';

/// Entry exposed only on the IO service — used by the picker UI
/// before any reminder is created. Not part of the cross-platform
/// interface because web / desktop don't have a calendar list to
/// pick from.
class RemindersCalendarChoice {
  const RemindersCalendarChoice({
    required this.id,
    required this.displayName,
    required this.accountName,
  });
  final String id;
  final String displayName;
  final String accountName;
}

class RemindersServiceIo implements RemindersService {
  static const MethodChannel _channel = MethodChannel('agent_buddy/reminders');

  /// Lists calendars the user can write to. Used by the picker
  /// sheet the first time the reminders tool is enabled.
  Future<List<RemindersCalendarChoice>> listWritableCalendars() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listCalendars');
    return (raw ?? const [])
        .map(
          (e) => RemindersCalendarChoice(
            id: (e as Map)['id'] as String? ?? '',
            displayName: (e)['displayName'] as String? ?? '',
            accountName: (e)['accountName'] as String? ?? '',
          ),
        )
        .where((c) => c.id.isNotEmpty)
        .toList();
  }

  /// Persists the chosen calendar as the "todo calendar". Throws
  /// [ToolException] if the native side is unavailable.
  Future<void> setTodoCalendar(String id) async {
    await _channel.invokeMethod<void>('setTodoCalendar', {'id': id});
  }

  /// Returns the currently chosen todo calendar id, or null if the
  /// user hasn't picked one yet.
  Future<String?> getTodoCalendar() async {
    final id = await _channel.invokeMethod<String?>('getTodoCalendar');
    return (id == null || id.isEmpty) ? null : id;
  }

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
  Future<List<Reminder>> listReminders({
    bool includeCompleted = false,
    int max = 50,
  }) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listReminders', {
      'includeCompleted': includeCompleted,
      'max': max,
    });
    return (raw ?? const [])
        .map((e) => Reminder.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  @override
  Future<Reminder> createReminder({
    required String title,
    String? notes,
    DateTime? due,
  }) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'createReminder',
      {'title': title, 'notes': notes, 'dueMs': due?.millisecondsSinceEpoch},
    );
    return Reminder.fromJson((raw ?? const {}).cast<String, dynamic>());
  }

  @override
  Future<Reminder?> completeReminder(String id) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
      'completeReminder',
      {'id': id},
    );
    if (raw == null) return null;
    return Reminder.fromJson(raw.cast<String, dynamic>());
  }

  @override
  Future<Reminder?> updateReminder(Reminder reminder) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>?>(
      'updateReminder',
      reminder.toJson(),
    );
    if (raw == null) return null;
    return Reminder.fromJson(raw.cast<String, dynamic>());
  }

  @override
  Future<bool> deleteReminder(String id) async {
    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'deleteReminder',
      {'id': id},
    );
    return raw?['ok'] as bool? ?? false;
  }
}
