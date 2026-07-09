import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_provider.dart';
import '../models/message.dart';
import '../models/provider.dart';
import '../models/role.dart';
import '../models/skill.dart';
import '../models/tool.dart';

class StorageService {
  static const _kProviders = 'providers';
  static const _kLocalProviders = 'local_providers';
  static const _kRoles = 'roles';
  static const _kTools = 'tools';
  static const _kSkills = 'skills';
  static const _kActiveProviderId = 'active_provider_id';
  static const _kActiveLocalProviderId = 'active_local_provider_id';
  static const _kUseLocalModel = 'use_local_model';
  static const _kActiveRoleId = 'active_role_id';
  static const _kActiveSkillIds = 'active_skill_ids';
  static const _kActiveToolIds = 'active_tool_ids';
  static const _kMessages = 'chat_messages';

  late final SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Providers
  List<ModelProvider> loadProviders() {
    final raw = _prefs.getStringList(_kProviders) ?? const [];
    return raw.map((e) => ModelProvider.fromRawJson(e)).toList();
  }

  Future<void> saveProviders(List<ModelProvider> providers) async {
    final raw = providers.map((e) => e.toRawJson()).toList();
    await _prefs.setStringList(_kProviders, raw);
  }

  String? get activeProviderId => _prefs.getString(_kActiveProviderId);
  Future<void> setActiveProviderId(String? id) async {
    if (id == null) {
      await _prefs.remove(_kActiveProviderId);
    } else {
      await _prefs.setString(_kActiveProviderId, id);
    }
  }

  // Local Providers
  List<LocalProvider> loadLocalProviders() {
    final raw = _prefs.getStringList(_kLocalProviders) ?? const [];
    return raw.map((e) => LocalProvider.fromRawJson(e)).toList();
  }

  Future<void> saveLocalProviders(List<LocalProvider> providers) async {
    final raw = providers.map((e) => e.toRawJson()).toList();
    await _prefs.setStringList(_kLocalProviders, raw);
  }

  String? get activeLocalProviderId =>
      _prefs.getString(_kActiveLocalProviderId);
  Future<void> setActiveLocalProviderId(String? id) async {
    if (id == null) {
      await _prefs.remove(_kActiveLocalProviderId);
    } else {
      await _prefs.setString(_kActiveLocalProviderId, id);
    }
  }

  bool get useLocalModel => _prefs.getBool(_kUseLocalModel) ?? false;
  Future<void> setUseLocalModel(bool value) async {
    await _prefs.setBool(_kUseLocalModel, value);
  }

  // Roles
  List<Role> loadRoles() {
    final raw = _prefs.getStringList(_kRoles) ?? const [];
    return raw.map((e) => Role.fromRawJson(e)).toList();
  }

  Future<void> saveRoles(List<Role> roles) async {
    final raw = roles.map((e) => e.toRawJson()).toList();
    await _prefs.setStringList(_kRoles, raw);
  }

  String? get activeRoleId => _prefs.getString(_kActiveRoleId);
  Future<void> setActiveRoleId(String? id) async {
    if (id == null) {
      await _prefs.remove(_kActiveRoleId);
    } else {
      await _prefs.setString(_kActiveRoleId, id);
    }
  }

  // Tools
  List<AgentTool> loadTools() {
    final raw = _prefs.getStringList(_kTools) ?? const [];
    return raw.map((e) => AgentTool.fromRawJson(e)).toList();
  }

  Future<void> saveTools(List<AgentTool> tools) async {
    final raw = tools.map((e) => e.toRawJson()).toList();
    await _prefs.setStringList(_kTools, raw);
  }

  List<String> get activeToolIds =>
      _prefs.getStringList(_kActiveToolIds) ?? const [];
  Future<void> setActiveToolIds(List<String> ids) async {
    await _prefs.setStringList(_kActiveToolIds, ids);
  }

  // Skills
  List<Skill> loadSkills() {
    final raw = _prefs.getStringList(_kSkills) ?? const [];
    return raw.map((e) => Skill.fromRawJson(e)).toList();
  }

  Future<void> saveSkills(List<Skill> skills) async {
    final raw = skills.map((e) => e.toRawJson()).toList();
    await _prefs.setStringList(_kSkills, raw);
  }

  List<String> get activeSkillIds =>
      _prefs.getStringList(_kActiveSkillIds) ?? const [];
  Future<void> setActiveSkillIds(List<String> ids) async {
    await _prefs.setStringList(_kActiveSkillIds, ids);
  }

  // Messages
  List<ChatMessage> loadMessages() {
    final raw = _prefs.getString(_kMessages);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages(List<ChatMessage> messages) async {
    final raw = jsonEncode(messages.map((e) => e.toJson()).toList());
    await _prefs.setString(_kMessages, raw);
  }
}
