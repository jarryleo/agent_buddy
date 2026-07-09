import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

enum BuiltinTool { fetchWeb, currentTime, askUser, runCommand, getEnvironment }

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
        return true;
      case BuiltinTool.runCommand:
      case BuiltinTool.getEnvironment:
        if (kIsWeb) return false;
        return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
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
