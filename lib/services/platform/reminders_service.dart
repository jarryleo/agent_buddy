import '../../models/reminder.dart';

import 'calendar_service.dart';

abstract class RemindersService {
  Future<PlatformPermissionStatus> ensurePermission();
  Future<List<Reminder>> listReminders({
    bool includeCompleted = false,
    int max = 50,
  });
  Future<Reminder> createReminder({
    required String title,
    String? notes,
    DateTime? due,
  });
  Future<Reminder?> completeReminder(String id);
  Future<Reminder?> updateReminder(Reminder reminder);
  Future<bool> deleteReminder(String id);
}
