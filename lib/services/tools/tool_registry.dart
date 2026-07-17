import 'tool_base.dart';
import 'fetch_web_tool.dart';
import 'current_time_tool.dart';
import 'ask_user_tool.dart';
import 'run_command_tool.dart';
import 'get_environment_tool.dart';
import 'calendar_tool.dart';
import 'reminders_tool.dart';
import 'notes_tool.dart';
import 'tasks_tool.dart';
import 'memory_tool.dart';
import 'location_tool.dart';
import 'download_tool.dart';
import 'file_tool.dart';
import 'load_skill_tool.dart';
import 'mcp_tool.dart';
import 'notification_tool.dart';
import 'timer_tool.dart';
import 'google_sheet_tool.dart';
import 'search_tool.dart';

/// Central registry that maps tool [id] to [ToolBase] instances.
///
/// Used by [ChatProvider], [SettingsProvider], and [ToolsTab] to
/// avoid giant switch statements scattered across the codebase.
class ToolRegistry {
  ToolRegistry._();

  static final Map<String, ToolBase> _all = <String, ToolBase>{
    for (final t in _buildAll()) t.id: t,
  };

  /// All built-in tool instances (unsorted).
  static List<ToolBase> get all => _all.values.toList();

  /// Look up a tool by its [id], or `null` if not found.
  static ToolBase? byId(String id) => _all[id];

  static List<ToolBase> _buildAll() => [
    // Core context & memory — AI self-awareness, most impactful
    MemoryTool(),
    CurrentTimeTool(),
    LocationTool(),

    // Information gathering
    FetchWebTool(),
    AskUserTool(),

    // Personal data management
    NotesTool(),
    TasksTool(),
    CalendarTool(),
    RemindersTool(),

    // Utilities
    DownloadTool(),
    RunCommandTool(),
    FileTool(),
    SearchTool(),
    GetEnvironmentTool(),

    // System (auto / not user-facing)
    LoadSkillTool(),

    // Push / scheduled callbacks to the user (runtime only).
    NotificationTool(),
    TimerTool(),

    // External services — third-party APIs the user signs into.
    GoogleSheetTool(),

    // MCP (Model Context Protocol) — dynamic external tool registration.
    McpTool(),
  ];
}
