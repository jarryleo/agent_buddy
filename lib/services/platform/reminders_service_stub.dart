import '../../models/reminder.dart';
import 'calendar_service.dart' show PlatformPermissionStatus;
import 'reminders_service.dart';

class RemindersServiceStub implements RemindersService {
  @override
  Future<PlatformPermissionStatus> ensurePermission() async =>
      PlatformPermissionStatus.notSupported;

  @override
  Future<List<Reminder>> listReminders({
    bool includeCompleted = false,
    int max = 50,
  }) async {
    throw UnsupportedError(
      'Reminders service is not supported on this platform',
    );
  }

  @override
  Future<Reminder> createReminder({
    required String title,
    String? notes,
    DateTime? due,
  }) async {
    throw UnsupportedError(
      'Reminders service is not supported on this platform',
    );
  }

  @override
  Future<Reminder?> completeReminder(String id) async {
    throw UnsupportedError(
      'Reminders service is not supported on this platform',
    );
  }

  @override
  Future<Reminder?> updateReminder(Reminder reminder) async {
    throw UnsupportedError(
      'Reminders service is not supported on this platform',
    );
  }

  @override
  Future<bool> deleteReminder(String id) async {
    throw UnsupportedError(
      'Reminders service is not supported on this platform',
    );
  }
}
