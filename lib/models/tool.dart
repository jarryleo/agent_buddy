import 'dart:convert';

enum BuiltinTool {
  fetchWeb,
  currentTime,
  askUser,
  runCommand,
  getEnvironment,
  calendar,
  reminders,
  notes,
  tasks,
  memory,
  location,
  download,
  googleSheet,
  todo,
}

/// Minimal extension: only provides the snake_case [id].
/// Name, description, platform rules live on [ToolBase] subclasses
/// in `lib/services/tools/`.
extension BuiltinToolX on BuiltinTool {
  String get id {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return 'fetch_web';
      case BuiltinTool.currentTime:
        return 'current_time';
      case BuiltinTool.askUser:
        return 'ask_user';
      case BuiltinTool.runCommand:
        return 'run_command';
      case BuiltinTool.getEnvironment:
        return 'get_environment';
      case BuiltinTool.calendar:
        return 'calendar';
      case BuiltinTool.reminders:
        return 'reminders';
      case BuiltinTool.notes:
        return 'notes';
      case BuiltinTool.tasks:
        return 'tasks';
      case BuiltinTool.memory:
        return 'memory';
      case BuiltinTool.location:
        return 'location';
      case BuiltinTool.download:
        return 'download';
      case BuiltinTool.googleSheet:
        return 'google_sheet';
      case BuiltinTool.todo:
        return 'todo';
    }
  }
}

class AgentTool {
  final String id;
  final String name;
  final String description;
  final bool enabled;

  AgentTool({
    required this.id,
    required this.name,
    required this.description,
    this.enabled = true,
  });

  AgentTool copyWith({String? name, String? description, bool? enabled}) {
    return AgentTool(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'enabled': enabled,
  };

  factory AgentTool.fromJson(Map<String, dynamic> json) {
    return AgentTool(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Tool',
      description: json['description'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory AgentTool.fromRawJson(String raw) =>
      AgentTool.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
