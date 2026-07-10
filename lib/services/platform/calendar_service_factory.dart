import 'dart:io' show Platform;

import 'calendar_service.dart';
import 'calendar_service_io.dart' as io;
import 'calendar_service_stub.dart' as stub;

CalendarService createCalendarService() {
  if (Platform.isAndroid || Platform.isIOS) {
    return io.CalendarServiceIo();
  }
  return stub.CalendarServiceStub();
}
