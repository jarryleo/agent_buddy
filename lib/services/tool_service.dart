import 'dart:async';

import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import '../models/memory.dart';
import '../models/note.dart';
import '../models/task.dart';
import 'memory_repository.dart';
import 'platform/calendar_service.dart';
import 'platform/calendar_service_factory.dart';
import 'platform/location_service.dart';
import 'platform/location_service_factory.dart' as location_factory;
import 'platform/notes_service.dart';
import 'platform/reminders_service.dart';
import 'platform/reminders_service_factory.dart';
import 'platform/tasks_service.dart';
import 'tools/tool_registry.dart';

/// Thrown by tool execution when a tool call fails. Carries a short,
/// human-readable message that is both shown to the AI (so it can
/// recover / retry) and surfaced in the chat UI as a failed tool call.
class ToolException implements Exception {
  ToolException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Shared service container for built-in tools.
///
/// Owns the lifecycle of platform-specific services (calendar,
/// reminders, notes, tasks, memories, location) and the HTTP
/// client used by [FetchWebTool]. Tool implementations receive
/// this as a context object so they can access the services they
/// need without coupling to each other.
class ToolService {
  ToolService({
    Box<Note>? notesBox,
    Box<Task>? tasksBox,
    Box<Memory>? memoriesBox,
    LocationServiceBuilder? locationBuilder,
    http.Client? httpClient,
  }) {
    if (notesBox != null) {
      _notes = NotesService()..open(preopened: notesBox);
    }
    if (tasksBox != null) {
      _tasks = TasksService()..open(preopened: tasksBox);
    }
    if (memoriesBox != null) {
      _memories = MemoryRepository()..open(preopened: memoriesBox);
    }
    _locationBuilder = locationBuilder;
    if (httpClient != null) {
      _client = httpClient;
      _ownsClient = false;
    } else {
      _client = http.Client();
      _ownsClient = true;
    }
  }

  late final http.Client _client;
  late final bool _ownsClient;

  CalendarService? _calendar;
  RemindersService? _reminders;
  NotesService? _notes;
  TasksService? _tasks;
  MemoryRepository? _memories;
  LocationServiceBuilder? _locationBuilder;
  LocationService? _location;

  /// The shared HTTP client used by [FetchWebTool].
  http.Client get httpClient => _client;

  CalendarService get calendar {
    _calendar ??= createCalendarService();
    return _calendar!;
  }

  RemindersService get reminders {
    _reminders ??= createRemindersService();
    return _reminders!;
  }

  NotesService get notes {
    _notes ??= NotesService()..open();
    return _notes!;
  }

  TasksService get tasks {
    _tasks ??= TasksService()..open();
    return _tasks!;
  }

  MemoryRepository get memories {
    _memories ??= MemoryRepository()..open();
    return _memories!;
  }

  LocationService get location {
    _location ??=
        (_locationBuilder ?? location_factory.createLocationService)();
    return _location!;
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }

  // -- Thin delegates for test backward compatibility --
  //
  // Each method builds the argument map the tool expects and
  // delegates to the tool's [execute]. Tests that call these
  // methods directly (e.g. `tools.fetchWeb(...)`) continue to work.

  Future<String> fetchWeb(
    String url, {
    String? linkText,
    bool includeLinks = false,
    int maxLength = 8000,
  }) async {
    final tool = ToolRegistry.byId('fetch_web')!;
    return tool.execute({
      'url': url,
      'link_text': linkText,
      'include_links': includeLinks,
      if (maxLength != 8000) 'max_length': maxLength,
    }, this);
  }

  Future<String> currentTime() async {
    final tool = ToolRegistry.byId('current_time')!;
    return tool.execute(const {}, this);
  }

  Future<String> runCommand({
    required String command,
    String? cwd,
    int timeoutSeconds = 30,
  }) async {
    final tool = ToolRegistry.byId('run_command')!;
    return tool.execute({
      'command': command,
      if (cwd != null) 'cwd': cwd, // ignore: use_null_aware_elements
      'timeout_seconds': timeoutSeconds,
    }, this);
  }

  Future<String> getEnvironment() async {
    final tool = ToolRegistry.byId('get_environment')!;
    return tool.execute(const {}, this);
  }

  Future<String> runCalendar(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('calendar')!;
    return tool.execute(args, this);
  }

  Future<String> runReminders(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('reminders')!;
    return tool.execute(args, this);
  }

  Future<String> runNotes(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('notes')!;
    return tool.execute(args, this);
  }

  Future<String> runTasks(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('tasks')!;
    return tool.execute(args, this);
  }

  Future<String> runMemory(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('memory')!;
    return tool.execute(args, this);
  }

  Future<String> runLocation(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('location')!;
    return tool.execute(args, this);
  }
}
