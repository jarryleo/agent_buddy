import 'dart:async';

import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import '../models/memory.dart';
import '../models/note.dart';
import '../models/task.dart';
import 'google_sheets_service.dart';
import 'mcp_service.dart';
import 'memory_repository.dart';
import 'notification_service.dart';
import 'platform/calendar_service.dart';
import 'platform/calendar_service_factory.dart';
import 'platform/file_service.dart';
import 'platform/file_service_factory.dart' as file_factory;
import 'platform/location_service.dart';
import 'platform/location_service_factory.dart' as location_factory;
import 'platform/notes_service.dart';
import 'platform/reminders_service.dart';
import 'platform/reminders_service_factory.dart';
import 'platform/tasks_service.dart';
import 'platform/working_dir_backend.dart';
import 'storage_service.dart';
import 'sub_agent_service.dart';
import 'timer_service.dart';
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
    FileServiceBuilder? fileBuilder,
    WorkingDirBackend? workingDirBackend,
    http.Client? httpClient,
    TimerService? timerService,
    NotificationService? notificationService,
    StorageService? storage,
    GoogleSheetsService? googleSheets,
    SubAgentService? subAgent,
  }) {
    _storage = storage;
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
    _fileBuilder = fileBuilder;
    _workingDirBackend = workingDirBackend;
    if (httpClient != null) {
      _client = httpClient;
      _ownsClient = false;
    } else {
      _client = http.Client();
      _ownsClient = true;
    }
    if (timerService != null) {
      _timers = timerService;
    }
    if (notificationService != null) {
      _notifications = notificationService;
    }
    if (googleSheets != null) {
      _googleSheets = googleSheets;
    } else if (storage != null) {
      _googleSheets = GoogleSheetsService(
        storage: storage,
        httpClient: _client,
      );
    }
    if (subAgent != null) {
      _subAgent = subAgent;
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
  FileServiceBuilder? _fileBuilder;
  WorkingDirBackend? _workingDirBackend;
  FileService? _file;
  TimerService? _timers;
  NotificationService? _notifications;
  McpService? _mcp;
  GoogleSheetsService? _googleSheets;
  SubAgentService? _subAgent;
  StorageService? _storage;

  /// The shared HTTP client used by [FetchWebTool].
  http.Client get httpClient => _client;
  String? get workingDirectory => _storage?.modelWorkingDirectory;

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

  /// Cross-platform file service used by the `file` tool's
  /// mobile branch. Falls back to a stub on non-supported
  /// platforms (web); tests can inject a fake via the
  /// [fileBuilder] constructor param.
  ///
  /// The production implementation gets a lazy lookup for the
  /// user-selected working directory so it always sees the
  /// latest value from `StorageService.modelWorkingDirectory`
  /// without manual sync. Tests that inject a fake via
  /// [fileBuilder] are responsible for their own working-dir
  /// surface.
  FileService get file {
    _file ??= (_fileBuilder ?? _createDefaultFileService)();
    return _file!;
  }

  FileService _createDefaultFileService() {
    // Wire the lazy working-directory lookup so the service
    // never holds a stale snapshot when the user picks a new
    // folder via the chat toolbar. The lookup only fires on
    // disk-backed ops (read / write / delete / rename /
    // list_dir / read_attr) and short-circuits to `null` when
    // storage isn't injected (e.g. unit tests that build a
    // `ToolService` without a `StorageService`).
    return file_factory.createFileService(
      workingDirectoryLookup: () => _storage?.modelWorkingDirectory,
      workingDirBackend: _workingDirBackend,
    );
  }

  /// The shared in-memory timer queue used by the `timer` tool
  /// and the in-app foreground notification. Always returns the
  /// same instance per `ToolService`; falls back to the global
  /// singleton if no instance was injected (e.g. in tests that
  /// build a `ToolService` without a ChatProvider in the loop).
  TimerService get timers {
    _timers ??= TimerService(notificationService: _notifications);
    return _timers!;
  }

  /// Shared MCP service for communicating with MCP servers.
  McpService get mcp {
    _mcp ??= McpService(httpClient: _client);
    return _mcp!;
  }

  /// Surfaces a notification via [NotificationService]. Thin
  /// pass-through so the `notification` tool doesn't have to
  /// reach into the global singleton directly — keeps everything
  /// routeable through `ToolService` for testability.
  Future<bool> notify({
    required String title,
    required String body,
    int? notificationId,
  }) {
    final svc = _notifications ?? NotificationService.instance;
    return svc.show(title: title, body: body, notificationId: notificationId);
  }

  /// The shared Google Sheets + OAuth coordinator used by the
  /// `google_sheet` tool. Falls back to a service that throws on
  /// every API call when no [StorageService] was injected (e.g.
  /// in unit tests that don't exercise the Sheets path) — keeps
  /// the type non-nullable while still failing loudly.
  GoogleSheetsService get googleSheets {
    if (_googleSheets != null) return _googleSheets!;
    throw StateError(
      'GoogleSheetsService is not available on this ToolService '
      '(no StorageService was injected)',
    );
  }

  /// The shared in-process sub-agent service used by the
  /// `subagent` tool. The chat provider constructs the singleton
  /// in `main.dart` and injects it via the [subAgent] constructor
  /// param so the tool layer can route delegation through it.
  /// Throws when no instance was injected (e.g. in unit tests
  /// that build a `ToolService` without going through the chat
  /// provider), which keeps the type non-nullable while still
  /// failing loudly.
  SubAgentService get subAgent {
    if (_subAgent != null) return _subAgent!;
    throw StateError(
      'SubAgentService is not available on this ToolService '
      '(no SubAgentService was injected)',
    );
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

  Future<String> runNotification(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('notification')!;
    return tool.execute(args, this);
  }

  Future<String> runTimer(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('timer')!;
    return tool.execute(args, this);
  }

  Future<String> runGoogleSheet(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('google_sheet')!;
    return tool.execute(args, this);
  }

  Future<String> runFile(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('file')!;
    return tool.execute(args, this);
  }

  Future<String> runSearch(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('search')!;
    return tool.execute(args, this);
  }

  Future<String> runSubAgent(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('subagent')!;
    return tool.execute(args, this);
  }

  Future<String> runEditImage(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('edit_image')!;
    return tool.execute(args, this);
  }

  /// `todo` tool dispatch. The tool itself just throws and
  /// routes the call back to `ChatProvider._onToolCall`; the
  /// thin delegate here exists for parity with the other
  /// `run*` helpers so tests / sub-agents that already go
  /// through `ToolService` keep working.
  Future<String> runTodo(Map<String, dynamic> args) async {
    final tool = ToolRegistry.byId('todo')!;
    return tool.execute(args, this);
  }
}
