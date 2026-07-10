import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

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
}

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
    }
  }

  String get name {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return 'Fetch Web';
      case BuiltinTool.currentTime:
        return 'Current Time';
      case BuiltinTool.askUser:
        return 'Ask User';
      case BuiltinTool.runCommand:
        return 'Run Command';
      case BuiltinTool.getEnvironment:
        return 'Get Environment';
      case BuiltinTool.calendar:
        return 'Calendar';
      case BuiltinTool.reminders:
        return 'Reminders';
      case BuiltinTool.notes:
        return 'Notes';
      case BuiltinTool.tasks:
        return 'Tasks';
      case BuiltinTool.memory:
        return 'Memory';
      case BuiltinTool.location:
        return 'Location';
    }
  }

  String get description {
    switch (this) {
      case BuiltinTool.fetchWeb:
        return '获取指定网址的内容,返回网页的纯文本。';
      case BuiltinTool.currentTime:
        return '获取当前日期与时间,返回本地时间、ISO 8601 与 Unix 时间戳。';
      case BuiltinTool.askUser:
        return '向用户提出一个多选或单选问题,用户作答后把结果回传给模型。';
      case BuiltinTool.runCommand:
        return '在主机上执行 shell 命令,返回 stdout、stderr 与退出码。仅桌面端 (Windows / macOS / Linux) 可用。';
      case BuiltinTool.getEnvironment:
        return '获取本机环境信息(OS、架构、用户、主目录、shell、内核版本),供模型在执行 run_command 前判断平台特定命令。仅桌面端 (Windows / macOS / Linux) 可用。';
      case BuiltinTool.calendar:
        return '管理手机系统日历(读取 / 创建 / 修改 / 删除 / 列出事件)。需要日历读取/写入权限。仅 Android / iOS 可用。';
      case BuiltinTool.reminders:
        return '管理提醒事项与待办(iOS: Reminders;Android: 日历全天事件)。需要提醒/日历写入权限。仅 Android / iOS 可用。';
      case BuiltinTool.notes:
        return '管理 Agent Buddy 内置笔记(数据存于本机 Hive,无需系统权限)。';
      case BuiltinTool.tasks:
        return '管理 Agent Buddy 内置任务清单(数据存于本机 Hive,无需系统权限)。Android 上作为"待办"的回退通路。';
      case BuiltinTool.memory:
        return '管理 AI 长期记忆:list / search(关键词模糊查询) / create(写入一条记忆) / get / delete / delete_batch。由 AI 自主判断何时写入或查询,不要在单轮内过度写入。';
      case BuiltinTool.location:
        return '获取用户当前的大致位置(经纬度 + 行政区划 + 时区)。移动端用 GPS 定位(需要授权),桌面/Web 用 IP 反查城市与时区。仅在用户问到天气、附近、本地时区等明确场景时调用,不要主动询问。';
    }
  }

  /// True on platforms that can actually run this tool. Used to skip
  /// the schema and the settings backfill on platforms where the
  /// underlying API isn't available.
  bool get isSupportedOnCurrentPlatform {
    switch (this) {
      case BuiltinTool.fetchWeb:
      case BuiltinTool.currentTime:
      case BuiltinTool.askUser:
      case BuiltinTool.notes:
      case BuiltinTool.tasks:
      case BuiltinTool.memory:
      case BuiltinTool.location:
        return true;
      case BuiltinTool.runCommand:
      case BuiltinTool.getEnvironment:
        if (kIsWeb) return false;
        return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
      case BuiltinTool.calendar:
      case BuiltinTool.reminders:
        if (kIsWeb) return false;
        return Platform.isAndroid || Platform.isIOS;
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
