import 'dart:io' show Platform;

import 'reminders_service.dart';
import 'reminders_service_io.dart' as io;
import 'reminders_service_stub.dart' as stub;

RemindersService createRemindersService() {
  if (Platform.isAndroid || Platform.isIOS) {
    return io.RemindersServiceIo();
  }
  return stub.RemindersServiceStub();
}
