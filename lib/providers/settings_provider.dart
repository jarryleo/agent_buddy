import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/local_provider.dart';
import '../models/mcp_provider.dart';
import '../models/provider.dart';
import '../models/role.dart';
import '../models/skill.dart';
import '../models/tool.dart';
import '../models/google_sheet_config.dart';
import '../services/google_sheets_service.dart';
import '../services/platform/autostart_service.dart';
import '../services/storage_service.dart';
import '../services/tools/tool_registry.dart';

class SettingsProvider extends ChangeNotifier {
  SettingsProvider(
    this._storage, [
    GoogleSheetsService? googleSheets,
    AutostartService? autostart,
  ]) : _googleSheets = googleSheets,
       _autostart = autostart {
    // Mirror the Google Sheet config into our cached copy so the
    // tools tab + auth-state UI see the latest state. The service
    // owns the persistence path (writes go through `_storage`); we
    // just keep our snapshot in sync so the toggle gate doesn't
    // re-open the settings sheet after a successful save.
    _googleSheets?.addListener(_onGoogleSheetsChanged);
  }

  final StorageService _storage;
  final GoogleSheetsService? _googleSheets;
  AutostartService? _autostart;
  final _uuid = const Uuid();

  List<ModelProvider> _providers = [];
  List<LocalProvider> _localProviders = [];
  List<Role> _roles = [];
  List<AgentTool> _tools = [];
  List<Skill> _skills = [];
  List<McpProvider> _mcpProviders = [];
  String? _activeProviderId;
  String? _activeLocalProviderId;
  bool _useLocalModel = false;
  String? _activeRoleId;
  Set<String> _activeToolIds = {};
  Set<String> _activeSkillIds = {};
  Set<String> _activeMcpIds = {};
  bool _toolsEnabled = true;
  String _themeMode = 'system';
  String _localeCode = 'system';
  String? _modelWorkingDirectory;
  String? _modelWorkingTreeUri;
  bool _thinkingModeEnabled = false;
  bool _autoStartEnabled = false;
  bool _showDesktopPet = false;
  bool _petAiBehaviorEnabled = false;
  String? _activePetId;
  GoogleSheetConfig _googleSheetConfig = GoogleSheetConfig.empty;

  List<ModelProvider> get providers => List.unmodifiable(_providers);
  List<LocalProvider> get localProviders => List.unmodifiable(_localProviders);
  List<Role> get roles => List.unmodifiable(_roles);
  List<AgentTool> get tools => List.unmodifiable(_tools);
  List<Skill> get skills => List.unmodifiable(_skills);
  List<McpProvider> get mcpProviders => List.unmodifiable(_mcpProviders);
  String? get activeProviderId => _activeProviderId;
  String? get activeLocalProviderId => _activeLocalProviderId;
  bool get useLocalModel => _useLocalModel;
  String? get activeRoleId => _activeRoleId;
  Set<String> get activeToolIds => Set.unmodifiable(_activeToolIds);
  Set<String> get activeSkillIds => Set.unmodifiable(_activeSkillIds);
  Set<String> get activeMcpIds => Set.unmodifiable(_activeMcpIds);
  bool get toolsEnabled => _toolsEnabled;
  String get themeMode => _themeMode;
  String get localeCode => _localeCode;
  String? get modelWorkingDirectory => _modelWorkingDirectory;

  /// Android-only: the SAF `content://` tree URI backing the
  /// working directory. The model never sees this value; the
  /// `FileService` plumbs it to the native side so that
  /// `DocumentFile` can write into the user's tree without
  /// requiring any `MANAGE_EXTERNAL_STORAGE` privilege.
  String? get modelWorkingTreeUri => _modelWorkingTreeUri;

  bool get thinkingModeEnabled => _thinkingModeEnabled;
  bool get autoStartEnabled => _autoStartEnabled;
  bool get showDesktopPet => _showDesktopPet;
  bool get petAiBehaviorEnabled => _petAiBehaviorEnabled;
  String? get activePetId => _activePetId;
  GoogleSheetConfig get googleSheetConfig => _googleSheetConfig;

  /// Called whenever `GoogleSheetsService` notifies (config writes,
  /// auth state transitions, tab list refreshes). We mirror the
  /// service's config into our cached copy so the tools tab toggle
  /// gate (`isFullyConfigured`) sees the latest state without
  /// needing to round-trip through SharedPreferences.
  ///
  /// `GoogleSheetConfig` is a value type — `updateSelection()` and
  /// `signOut()` always produce a new instance via `copyWith`, so
  /// reference equality is a safe change detector here. The listener
  /// fires on every notify regardless; if the data happens to match,
  /// the UI sees no visual diff and skips the rebuild on its own.
  void _onGoogleSheetsChanged() {
    final svc = _googleSheets;
    if (svc == null) return;
    if (identical(_googleSheetConfig, svc.config)) return;
    _googleSheetConfig = svc.config;
    notifyListeners();
  }

  @override
  void dispose() {
    _googleSheets?.removeListener(_onGoogleSheetsChanged);
    super.dispose();
  }

  ModelProvider? get activeProvider {
    if (_activeProviderId == null) return null;
    for (final p in _providers) {
      if (p.id == _activeProviderId) return p;
    }
    return null;
  }

  LocalProvider? get activeLocalProvider {
    if (_activeLocalProviderId == null) return null;
    for (final p in _localProviders) {
      if (p.id == _activeLocalProviderId) return p;
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

  List<AgentTool> get activeTools {
    // The master switch wins over per-tool selection: if the user
    // has turned tools off globally (to save tokens in a pure-chat
    // scenario), no tool is exposed to the model even if individual
    // switches are still flipped on. Per-tool state is preserved so
    // toggling the master back on restores the previous selection.
    if (!_toolsEnabled) return const [];
    return _tools.where((t) => _activeToolIds.contains(t.id)).toList();
  }

  List<Skill> get activeSkills =>
      _skills.where((s) => _activeSkillIds.contains(s.id)).toList();

  Future<void> load() async {
    _providers = _storage.loadProviders();
    _localProviders = _storage.loadLocalProviders();
    _roles = _storage.loadRoles();
    _tools = _storage.loadTools();
    _skills = _storage.loadSkills();
    _mcpProviders = _storage.loadMcpProviders();
    _activeProviderId = _storage.activeProviderId;
    _activeLocalProviderId = _storage.activeLocalProviderId;
    _useLocalModel = _storage.useLocalModel;
    _activeRoleId = _storage.activeRoleId;
    _activeToolIds = _storage.activeToolIds.toSet();
    _activeSkillIds = _storage.activeSkillIds.toSet();
    _activeMcpIds = _storage.activeMcpIds.toSet();
    _toolsEnabled = _storage.toolsEnabled;
    _themeMode = _storage.themeMode;
    _localeCode = _storage.localeCode;
    _modelWorkingDirectory = _storage.modelWorkingDirectory;
    _modelWorkingTreeUri = _storage.modelWorkingTreeUri;
    _thinkingModeEnabled = _storage.thinkingModeEnabled;
    _autoStartEnabled = _storage.autoStartEnabled;
    _showDesktopPet = _storage.showDesktopPet;
    _petAiBehaviorEnabled = _storage.petAiBehaviorEnabled;
    _activePetId = _storage.activePetId;
    _googleSheetConfig = _storage.loadGoogleSheetConfig();

    // Seed built-in tools. Fresh installs hit the `isEmpty` branch and
    // get every builtin; existing installs hit the second branch which
    // back-fills any builtin that's missing (e.g. a user upgrading
    // from a build that didn't have `current_time`).
    // Name and description come from the ToolBase subclass. The
    // per-row `enabled` flag honours the tool's own
    // `isEnabledByDefault` — some tools (e.g. `reminders`) need
    // one-time setup so they start off and the settings tab walks
    // the user through the picker.
    if (_tools.isEmpty) {
      _tools = [
        for (final t in ToolRegistry.all)
          if (t.isSupportedOnCurrentPlatform)
            AgentTool(
              id: t.id,
              name: t.name,
              description: t.description,
              enabled: t.isEnabledByDefault,
            ),
      ];
      await _storage.saveTools(_tools);
    } else {
      final existingIds = _tools.map((t) => t.id).toSet();
      var changed = false;
      for (final t in ToolRegistry.all) {
        if (!t.isSupportedOnCurrentPlatform) continue;
        if (!existingIds.contains(t.id)) {
          _tools = [
            ..._tools,
            AgentTool(
              id: t.id,
              name: t.name,
              description: t.description,
              enabled: t.isEnabledByDefault,
            ),
          ];
          changed = true;
        }
      }
      if (changed) await _storage.saveTools(_tools);
    }

    // Sort tools to match registry order for consistent display.
    {
      final order = <String, int>{};
      for (var i = 0; i < ToolRegistry.all.length; i++) {
        order[ToolRegistry.all[i].id] = i;
      }
      _tools.sort((a, b) => (order[a.id] ?? 999).compareTo(order[b.id] ?? 999));
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

    // Default active local provider = first enabled
    if (_activeLocalProviderId == null && _localProviders.isNotEmpty) {
      final enabled = _localProviders.firstWhere(
        (p) => p.enabled,
        orElse: () => _localProviders.first,
      );
      _activeLocalProviderId = enabled.id;
      await _storage.setActiveLocalProviderId(_activeLocalProviderId);
    }

    // Default active tools: every built-in tool that defaults to
    // on, so the user gets the full default set without having to
    // flip switches. Tools that default to off (e.g. `reminders`,
    // which needs the user to pick a "todo" calendar on Android)
    // are NOT auto-enabled — the user has to turn them on in the
    // tools tab, which kicks off the picker.
    // For existing installs, only backfill builtins that aren't in
    // the list yet AND default to on. A user who explicitly turned
    // something off keeps it off, while a newly-shipped on-by-
    // default builtin (e.g. upgrading from a build that didn't
    // have `current_time`) is enabled automatically. Newly-shipped
    // off-by-default builtins stay off until the user opts in.
    if (_activeToolIds.isEmpty) {
      _activeToolIds = {
        for (final t in ToolRegistry.all)
          if (t.isSupportedOnCurrentPlatform && t.isEnabledByDefault) t.id,
      };
      await _storage.setActiveToolIds(_activeToolIds.toList());
    } else {
      var changed = false;
      for (final t in ToolRegistry.all) {
        if (!t.isSupportedOnCurrentPlatform) continue;
        if (!t.isEnabledByDefault) continue;
        if (!_activeToolIds.contains(t.id)) {
          _activeToolIds.add(t.id);
          changed = true;
        }
      }
      if (changed) {
        await _storage.setActiveToolIds(_activeToolIds.toList());
      }
    }

    // Seed built-in skills. Mirrors the tool loop above: fresh
    // installs get every built-in added and enabled; existing
    // installs get any new built-in back-filled (so a user
    // upgrading from a build that didn't have `news` / `weather`
    // picks them up automatically and they start out active).
    // User-added skills are never touched by this loop.
    if (_skills.isEmpty) {
      _skills = [for (final s in BuiltinSkills.all) s.toSkill()];
    } else {
      final existingIds = _skills.map((s) => s.id).toSet();
      var added = false;
      for (final s in BuiltinSkills.all) {
        if (!existingIds.contains(s.id)) {
          _skills = [..._skills, s.toSkill()];
          added = true;
        }
      }
      if (added) {
        await _storage.saveSkills(_skills);
      }
    }
    // Drop built-ins that have been removed in a newer build
    // (e.g. `tool_usage` was merged into per-tool
    // `compactSchemaForModel` — its persisted row should not
    // linger in the user's skill list or show up in
    // `_activeSkillIds`). User-added skills are never touched.
    final builtinIds = BuiltinSkills.all.map((s) => s.id).toSet();
    final beforeDrop = _skills.length;
    _skills = _skills
        .where((s) => !s.isBuiltin || builtinIds.contains(s.id))
        .toList();
    if (_skills.length != beforeDrop) {
      // Also drop the now-orphan id from the active set so it
      // doesn't keep surfacing in the active-skill count.
      _activeSkillIds.removeWhere(
        (id) =>
            id.startsWith(Skill.builtinIdPrefix) && !builtinIds.contains(id),
      );
      await _storage.saveSkills(_skills);
      await _storage.setActiveSkillIds(_activeSkillIds.toList());
    }

    // Auto-enable any new built-in (and re-enable any existing
    // built-in the user previously toggled on). Built-ins start
    // active; a user can still toggle them off, and that choice
    // sticks across launches because we only `add`, never
    // blindly `clear` here.
    var skillsChanged = false;
    for (final s in _skills) {
      if (s.isBuiltin && s.enabled && !_activeSkillIds.contains(s.id)) {
        _activeSkillIds.add(s.id);
        skillsChanged = true;
      }
    }
    if (skillsChanged) {
      await _storage.setActiveSkillIds(_activeSkillIds.toList());
    }

    // MCP providers: auto-enable any new ones.
    if (_activeMcpIds.isEmpty) {
      _activeMcpIds = {
        for (final m in _mcpProviders)
          if (m.enabled) m.id,
      };
      await _storage.setActiveMcpIds(_activeMcpIds.toList());
    }
    for (final m in _mcpProviders) {
      if (m.enabled && !_activeMcpIds.contains(m.id)) {
        _activeMcpIds.add(m.id);
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

  Future<void> setProviderSelectedModel(
    String providerId,
    String? model,
  ) async {
    _providers = [
      for (final p in _providers)
        if (p.id == providerId) p.copyWith(selectedModel: model) else p,
    ];
    await _storage.saveProviders(_providers);
    notifyListeners();
  }

  // Local providers

  /// User-added local providers (i.e. ones NOT managed by a
  /// built-in model card). The local model settings list renders
  /// this view — built-in providers are surfaced by the built-in
  /// cards themselves to avoid showing the same model twice.
  List<LocalProvider> get customLocalProviders =>
      _localProviders.where((p) => p.builtinModelId == null).toList();

  /// Returns the configured [LocalProvider] linked to the given
  /// built-in model id, or `null` when the user hasn't completed
  /// the download + save flow for that built-in yet. Used by the
  /// built-in cards in the local model settings tab to surface the
  /// "已配置 / 未配置" state.
  LocalProvider? localProviderForBuiltin(String builtinModelId) {
    for (final p in _localProviders) {
      if (p.builtinModelId == builtinModelId) return p;
    }
    return null;
  }

  Future<LocalProvider> addLocalProvider({
    required String name,
    required String modelPath,
    String? mmprojPath,
    int contextSize = 4096,
    double temperature = 0.7,
    int gpuLayers = 0,
    int maxTokens = 1024,
    String cacheTypeK = 'f16',
    String cacheTypeV = 'f16',
    int batchSize = LocalProvider.kDefaultBatchSize,
    int? thinkingBudgetTokens,
    String? chatTemplate,
    String? builtinModelId,
  }) async {
    final provider = LocalProvider(
      id: _uuid.v4(),
      name: name,
      modelPath: modelPath,
      mmprojPath: mmprojPath,
      contextSize: contextSize,
      temperature: temperature,
      gpuLayers: gpuLayers,
      maxTokens: maxTokens,
      cacheTypeK: cacheTypeK,
      cacheTypeV: cacheTypeV,
      batchSize: batchSize,
      thinkingBudgetTokens: thinkingBudgetTokens,
      chatTemplate: chatTemplate,
      builtinModelId: builtinModelId,
    );
    _localProviders = [..._localProviders, provider];
    if (_activeLocalProviderId == null) {
      _activeLocalProviderId = provider.id;
      await _storage.setActiveLocalProviderId(_activeLocalProviderId);
    }
    await _storage.saveLocalProviders(_localProviders);
    notifyListeners();
    return provider;
  }

  Future<void> updateLocalProvider(LocalProvider provider) async {
    _localProviders = [
      for (final p in _localProviders) p.id == provider.id ? provider : p,
    ];
    await _storage.saveLocalProviders(_localProviders);
    notifyListeners();
  }

  Future<void> deleteLocalProvider(String id) async {
    _localProviders = _localProviders.where((p) => p.id != id).toList();
    if (_activeLocalProviderId == id) {
      _activeLocalProviderId = _localProviders.isNotEmpty
          ? _localProviders.first.id
          : null;
      await _storage.setActiveLocalProviderId(_activeLocalProviderId);
    }
    await _storage.saveLocalProviders(_localProviders);
    notifyListeners();
  }

  Future<void> toggleLocalProvider(String id, bool enabled) async {
    _localProviders = [
      for (final p in _localProviders)
        p.id == id ? p.copyWith(enabled: enabled) : p,
    ];
    await _storage.saveLocalProviders(_localProviders);
    notifyListeners();
  }

  Future<void> setActiveLocalProvider(String id) async {
    _activeLocalProviderId = id;
    await _storage.setActiveLocalProviderId(id);
    notifyListeners();
  }

  Future<void> setUseLocalModel(bool value) async {
    _useLocalModel = value;
    await _storage.setUseLocalModel(value);
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
    _roles = [for (final r in _roles) r.id == role.id ? role : r];
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
  Future<void> setToolsEnabled(bool value) async {
    _toolsEnabled = value;
    await _storage.setToolsEnabled(value);
    notifyListeners();
  }

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
    _activeSkillIds.add(skill.id);
    await _storage.saveSkills(_skills);
    await _storage.setActiveSkillIds(_activeSkillIds.toList());
    notifyListeners();
    return skill;
  }

  Future<void> updateSkill(Skill skill) async {
    _skills = [for (final s in _skills) s.id == skill.id ? skill : s];
    await _storage.saveSkills(_skills);
    notifyListeners();
  }

  Future<void> deleteSkill(String id) async {
    // Built-in skills are part of the app — refuse to delete them
    // so the next launch doesn't silently re-seed what the user
    // just removed. The UI hides the delete button for built-ins;
    // this guard is a belt-and-suspenders defense.
    if (id.startsWith(Skill.builtinIdPrefix)) return;
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

  // MCP Providers
  Future<McpProvider> addMcpProvider({
    required String name,
    required String jsonConfig,
  }) async {
    final provider = McpProvider(
      id: _uuid.v4(),
      name: name,
      jsonConfig: jsonConfig,
    );
    _mcpProviders = [..._mcpProviders, provider];
    _activeMcpIds.add(provider.id);
    await _storage.saveMcpProviders(_mcpProviders);
    await _storage.setActiveMcpIds(_activeMcpIds.toList());
    notifyListeners();
    return provider;
  }

  Future<void> updateMcpProvider(McpProvider provider) async {
    _mcpProviders = [
      for (final m in _mcpProviders) m.id == provider.id ? provider : m,
    ];
    await _storage.saveMcpProviders(_mcpProviders);
    notifyListeners();
  }

  Future<void> deleteMcpProvider(String id) async {
    _mcpProviders = _mcpProviders.where((m) => m.id != id).toList();
    _activeMcpIds.remove(id);
    await _storage.saveMcpProviders(_mcpProviders);
    await _storage.setActiveMcpIds(_activeMcpIds.toList());
    notifyListeners();
  }

  Future<void> toggleMcpProvider(String id, bool enabled) async {
    _mcpProviders = [
      for (final m in _mcpProviders)
        m.id == id ? m.copyWith(enabled: enabled) : m,
    ];
    if (enabled) {
      _activeMcpIds.add(id);
    } else {
      _activeMcpIds.remove(id);
    }
    await _storage.saveMcpProviders(_mcpProviders);
    await _storage.setActiveMcpIds(_activeMcpIds.toList());
    notifyListeners();
  }

  // General
  Future<void> setThemeMode(String mode) async {
    _themeMode = mode;
    await _storage.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setLocaleCode(String code) async {
    _localeCode = code;
    await _storage.setLocaleCode(code);
    notifyListeners();
  }

  /// Persist the user-selected working directory. Called by
  /// the chat toolbar's "pick folder" flow:
  ///   * **Android** — both `path` and `treeUri` are
  ///     populated by `FileService.pickWorkingDirectory()`
  ///     (which goes through the native `FileBridge` SAF
  ///     tree picker). `path` is the display path the user
  ///     sees in the toolbar tooltip; `treeUri` is the
  ///     `content://` URI the native side needs to write
  ///     into the folder. The native bridge also writes the
  ///     `treeUri` to its own SharedPreferences mirror, so
  ///     this just records it for the Dart-side `StorageService`
  ///     lookup.
  ///   * **iOS / desktop** — only `path` is set; `treeUri` is
  ///     `null` (iOS uses the app sandbox, so `dart:io` is
  ///     enough; desktop doesn't gate paths).
  /// Pass `path: null` to clear the working directory (which
  /// also drops any stale tree URI on Android).
  Future<void> setModelWorkingDirectory({String? path, String? treeUri}) async {
    final normalizedPath = path?.trim();
    _modelWorkingDirectory = normalizedPath == null || normalizedPath.isEmpty
        ? null
        : normalizedPath;
    await _storage.setModelWorkingDirectory(_modelWorkingDirectory);
    if (_modelWorkingDirectory == null) {
      // Clearing the path also drops any stale tree URI so
      // the next `pickWorkingDirectory` starts from a clean
      // slate.
      _modelWorkingTreeUri = null;
      await _storage.setModelWorkingTreeUri(null);
    } else if (treeUri != null && treeUri.isNotEmpty) {
      // Android re-pick: surface the freshly-granted tree
      // URI to the Dart-side storage so the next
      // `FileService` op can pick it up.
      _modelWorkingTreeUri = treeUri;
      await _storage.setModelWorkingTreeUri(treeUri);
    }
    notifyListeners();
  }

  /// Android-only: persist the SAF `content://` tree URI
  /// that backs the user-selected working directory. Called
  /// directly by the native bridge via the SettingsProvider
  /// when it refreshes the tree grant. Most callers should
  /// use [setModelWorkingDirectory] instead — this is here
  /// for completeness and for tests that want to inject a
  /// tree URI without going through the picker.
  Future<void> setModelWorkingTreeUri(String? uri) async {
    final normalized = uri == null || uri.isEmpty ? null : uri;
    _modelWorkingTreeUri = normalized;
    await _storage.setModelWorkingTreeUri(_modelWorkingTreeUri);
    notifyListeners();
  }

  Future<void> setThinkingModeEnabled(bool enabled) async {
    _thinkingModeEnabled = enabled;
    await _storage.setThinkingModeEnabled(enabled);
    notifyListeners();
  }

  /// Inject the concrete [AutostartService] used to talk to the
  /// OS-level startup hook. Wired up after construction because
  /// `createAutostartService()` consults [Platform.isWindows] etc.,
  /// which aren't fully resolved inside `main()` until after
  /// `WidgetsFlutterBinding.ensureInitialized()` runs. Tests can
  /// pass a fake via the third positional arg of the constructor.
  ///
  /// If the user has previously enabled auto-start, we *re-apply*
  /// it on every startup so the OS state and our cached
  /// preference stay in sync — e.g. the user could have wiped the
  /// `~/.config/autostart/agent-buddy.desktop` file from another
  /// tool, and we'd want the next launch to put it back. If the
  /// service says it failed to apply, we silently swallow the
  /// error: the cached preference stays at the user's last
  /// intent, and the toggle in settings still works — they can
  /// re-toggle to retry.
  void attachAutostartService(AutostartService? service) {
    _autostart = service;
    if (service != null && service.isSupported && _autoStartEnabled) {
      // Fire-and-forget: we don't want settings load to block on
      // a slow `reg add` round-trip. The user-facing toggle in
      // the general settings tab awaits the same call.
      // ignore: discarded_futures
      service.setEnabled(true);
    }
  }

  /// Toggle the "launch at login" preference. Calls into the
  /// [AutostartService] so the OS state and the cached preference
  /// are kept in lock-step. Returns `true` when the OS state was
  /// successfully updated; `false` when the write failed (the
  /// caller can surface a snackbar). On non-desktop platforms
  /// (`_autostart == null` or `isSupported == false`) we still
  /// persist the preference so a desktop upgrade on the same
  /// device restores it.
  Future<bool> setAutoStartEnabled(bool enabled) async {
    _autoStartEnabled = enabled;
    await _storage.setAutoStartEnabled(enabled);
    final svc = _autostart;
    if (svc == null || !svc.isSupported) {
      notifyListeners();
      return true;
    }
    final result = await svc.setEnabled(enabled);
    // `null` = write failed; the OS state may be out of sync
    // with our cached value. Surface the failure to the caller
    // so the settings tab can roll the switch back. On success
    // we trust the OS verdict (true / false) and mirror it.
    if (result != null) {
      _autoStartEnabled = result;
      await _storage.setAutoStartEnabled(result);
    }
    notifyListeners();
    return result != null;
  }

  /// Master toggle for the desktop pet window. Persists the
  /// preference and notifies so the lifecycle owner can spawn or
  /// close the pet window accordingly. Pass `activePetId: null` to
  /// fall back to the bundled Anya; pass an explicit id to lock
  /// the choice to a specific pet.
  Future<void> setShowDesktopPet(bool enabled, {String? activePetId}) async {
    _showDesktopPet = enabled;
    await _storage.setShowDesktopPet(enabled);
    if (activePetId != null) {
      _activePetId = activePetId;
      await _storage.setActivePetId(activePetId);
    }
    notifyListeners();
  }

  /// Secondary switch that lets the active pet auto-orchestrate
  /// idle-time behavior by asking the active model to plan a
  /// sequence of actions. The director listens for this flag and
  /// arms/disarms the 1-minute idle timer. No effect without the
  /// master [showDesktopPet] toggle on.
  Future<void> setPetAiBehaviorEnabled(bool enabled) async {
    _petAiBehaviorEnabled = enabled;
    await _storage.setPetAiBehaviorEnabled(enabled);
    notifyListeners();
  }

  /// Records the user's pick. `null` clears the selection; the
  /// pet lifecycle code falls back to the bundled Anya in that
  /// case so the toggle still has something to render.
  Future<void> setActivePetId(String? id) async {
    _activePetId = (id == null || id.isEmpty) ? null : id;
    await _storage.setActivePetId(_activePetId);
    notifyListeners();
  }
}
