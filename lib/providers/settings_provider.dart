import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/provider.dart';
import '../models/role.dart';
import '../models/skill.dart';
import '../models/tool.dart';
import '../services/storage_service.dart';

class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._storage);

  final StorageService _storage;
  final _uuid = const Uuid();

  List<ModelProvider> _providers = [];
  List<Role> _roles = [];
  List<AgentTool> _tools = [];
  List<Skill> _skills = [];
  String? _activeProviderId;
  String? _activeRoleId;
  Set<String> _activeToolIds = {};
  Set<String> _activeSkillIds = {};

  List<ModelProvider> get providers => List.unmodifiable(_providers);
  List<Role> get roles => List.unmodifiable(_roles);
  List<AgentTool> get tools => List.unmodifiable(_tools);
  List<Skill> get skills => List.unmodifiable(_skills);
  String? get activeProviderId => _activeProviderId;
  String? get activeRoleId => _activeRoleId;
  Set<String> get activeToolIds => Set.unmodifiable(_activeToolIds);
  Set<String> get activeSkillIds => Set.unmodifiable(_activeSkillIds);

  ModelProvider? get activeProvider {
    if (_activeProviderId == null) return null;
    for (final p in _providers) {
      if (p.id == _activeProviderId) return p;
    }
    return null;
  }

  Role? get activeRole {
    if (_activeRoleId == null) return null;
    for (final r in _roles) {
      if (r.id == _activeRoleId) return r;
    }
    return null;
  }

  List<AgentTool> get activeTools =>
      _tools.where((t) => _activeToolIds.contains(t.id)).toList();
  List<Skill> get activeSkills =>
      _skills.where((s) => _activeSkillIds.contains(s.id)).toList();

  Future<void> load() async {
    _providers = _storage.loadProviders();
    _roles = _storage.loadRoles();
    _tools = _storage.loadTools();
    _skills = _storage.loadSkills();
    _activeProviderId = _storage.activeProviderId;
    _activeRoleId = _storage.activeRoleId;
    _activeToolIds = _storage.activeToolIds.toSet();
    _activeSkillIds = _storage.activeSkillIds.toSet();

    // Seed built-in tools. Fresh installs hit the `isEmpty` branch and
    // get every builtin; existing installs hit the second branch which
    // back-fills any builtin that's missing (e.g. a user upgrading
    // from a build that didn't have `current_time`).
    if (_tools.isEmpty) {
      _tools = [
        for (final b in BuiltinTool.values)
          AgentTool(
            id: b.id,
            name: b.name,
            description: b.description,
            enabled: true,
          ),
      ];
      await _storage.saveTools(_tools);
    } else {
      final existingIds = _tools.map((t) => t.id).toSet();
      var changed = false;
      for (final b in BuiltinTool.values) {
        if (!existingIds.contains(b.id)) {
          _tools = [
            ..._tools,
            AgentTool(
              id: b.id,
              name: b.name,
              description: b.description,
              enabled: true,
            ),
          ];
          changed = true;
        }
      }
      if (changed) await _storage.saveTools(_tools);
    }

    // Default active provider = first enabled
    if (_activeProviderId == null && _providers.isNotEmpty) {
      final enabled = _providers.firstWhere(
        (p) => p.enabled,
        orElse: () => _providers.first,
      );
      _activeProviderId = enabled.id;
      await _storage.setActiveProviderId(_activeProviderId);
    }

    // Default active tools: every built-in tool, so the user gets
    // them out of the box without having to toggle anything on.
    // For existing installs, only backfill builtins that aren't in
    // the list yet — that way a user who explicitly turned something
    // off keeps it off, while a newly-shipped builtin (e.g. upgrading
    // from a build that didn't have `current_time`) is enabled.
    if (_activeToolIds.isEmpty) {
      _activeToolIds = {for (final b in BuiltinTool.values) b.id};
      await _storage.setActiveToolIds(_activeToolIds.toList());
    } else {
      var changed = false;
      for (final b in BuiltinTool.values) {
        if (!_activeToolIds.contains(b.id)) {
          _activeToolIds.add(b.id);
          changed = true;
        }
      }
      if (changed) {
        await _storage.setActiveToolIds(_activeToolIds.toList());
      }
    }

    notifyListeners();
  }

  // Provider
  Future<ModelProvider> addProvider({
    required String name,
    required ProviderProtocol protocol,
    required String baseUrl,
    required String apiKey,
    required String chatPath,
  }) async {
    final provider = ModelProvider(
      id: _uuid.v4(),
      name: name,
      protocol: protocol,
      baseUrl: baseUrl,
      apiKey: apiKey,
      chatPath: chatPath,
    );
    _providers = [..._providers, provider];
    if (_activeProviderId == null) {
      _activeProviderId = provider.id;
      await _storage.setActiveProviderId(_activeProviderId);
    }
    await _storage.saveProviders(_providers);
    notifyListeners();
    return provider;
  }

  Future<void> updateProvider(ModelProvider provider) async {
    _providers = [
      for (final p in _providers) p.id == provider.id ? provider : p,
    ];
    await _storage.saveProviders(_providers);
    notifyListeners();
  }

  Future<void> deleteProvider(String id) async {
    _providers = _providers.where((p) => p.id != id).toList();
    if (_activeProviderId == id) {
      _activeProviderId = _providers.isNotEmpty ? _providers.first.id : null;
      await _storage.setActiveProviderId(_activeProviderId);
    }
    await _storage.saveProviders(_providers);
    notifyListeners();
  }

  Future<void> toggleProvider(String id, bool enabled) async {
    _providers = [
      for (final p in _providers) p.id == id ? p.copyWith(enabled: enabled) : p,
    ];
    await _storage.saveProviders(_providers);
    notifyListeners();
  }

  Future<void> setActiveProvider(String id) async {
    _activeProviderId = id;
    await _storage.setActiveProviderId(id);
    notifyListeners();
  }

  Future<void> setProviderSelectedModel(String providerId, String? model) async {
    _providers = [
      for (final p in _providers)
        if (p.id == providerId) p.copyWith(selectedModel: model) else p,
    ];
    await _storage.saveProviders(_providers);
    notifyListeners();
  }

  // Role
  Future<Role> addRole({
    required String name,
    String avatar = '',
    String description = '',
    String systemPrompt = '',
  }) async {
    final role = Role(
      id: _uuid.v4(),
      name: name,
      avatar: avatar,
      description: description,
      systemPrompt: systemPrompt,
    );
    _roles = [..._roles, role];
    await _storage.saveRoles(_roles);
    notifyListeners();
    return role;
  }

  Future<void> updateRole(Role role) async {
    _roles = [
      for (final r in _roles) r.id == role.id ? role : r,
    ];
    await _storage.saveRoles(_roles);
    notifyListeners();
  }

  Future<void> deleteRole(String id) async {
    _roles = _roles.where((r) => r.id != id).toList();
    if (_activeRoleId == id) {
      _activeRoleId = null;
      await _storage.setActiveRoleId(null);
    }
    await _storage.saveRoles(_roles);
    notifyListeners();
  }

  Future<void> toggleRole(String id, bool enabled) async {
    _roles = [
      for (final r in _roles) r.id == id ? r.copyWith(enabled: enabled) : r,
    ];
    await _storage.saveRoles(_roles);
    notifyListeners();
  }

  Future<void> setActiveRole(String? id) async {
    _activeRoleId = id;
    await _storage.setActiveRoleId(id);
    notifyListeners();
  }

  // Tools
  Future<void> toggleTool(String id, bool enabled) async {
    _tools = [
      for (final t in _tools) t.id == id ? t.copyWith(enabled: enabled) : t,
    ];
    if (enabled) {
      _activeToolIds.add(id);
    } else {
      _activeToolIds.remove(id);
    }
    await _storage.saveTools(_tools);
    await _storage.setActiveToolIds(_activeToolIds.toList());
    notifyListeners();
  }

  // Skills
  Future<Skill> addSkill({
    required String name,
    String description = '',
    String content = '',
  }) async {
    final skill = Skill(
      id: _uuid.v4(),
      name: name,
      description: description,
      content: content,
    );
    _skills = [..._skills, skill];
    await _storage.saveSkills(_skills);
    notifyListeners();
    return skill;
  }

  Future<void> updateSkill(Skill skill) async {
    _skills = [
      for (final s in _skills) s.id == skill.id ? skill : s,
    ];
    await _storage.saveSkills(_skills);
    notifyListeners();
  }

  Future<void> deleteSkill(String id) async {
    _skills = _skills.where((s) => s.id != id).toList();
    _activeSkillIds.remove(id);
    await _storage.saveSkills(_skills);
    await _storage.setActiveSkillIds(_activeSkillIds.toList());
    notifyListeners();
  }

  Future<void> toggleSkill(String id, bool enabled) async {
    _skills = [
      for (final s in _skills) s.id == id ? s.copyWith(enabled: enabled) : s,
    ];
    if (enabled) {
      _activeSkillIds.add(id);
    } else {
      _activeSkillIds.remove(id);
    }
    await _storage.saveSkills(_skills);
    await _storage.setActiveSkillIds(_activeSkillIds.toList());
    notifyListeners();
  }
}
