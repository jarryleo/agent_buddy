import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_session.dart';
import '../models/google_sheet_config.dart';
import '../models/local_provider.dart';
import '../models/mcp_provider.dart';
import '../models/message.dart';
import '../models/provider.dart';
import '../models/role.dart';
import '../models/skill.dart';
import '../models/tool.dart';
import 'chat_session_repository.dart';

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
  static const _kToolsEnabled = 'tools_enabled';
  // Legacy key for the pre-session "single list of messages" model.
  // Kept for one migration on app start; new writes go to Hive.
  static const _kLegacyMessages = 'chat_messages';
  static const _kMcpProviders = 'mcp_providers';
  static const _kActiveMcpIds = 'active_mcp_ids';
  static const _kActiveSessionId = 'active_session_id';
  static const _kThemeMode = 'theme_mode';
  static const _kLocaleCode = 'locale_code';
  static const _kGoogleSheetConfig = 'google_sheet_config';
  static const _kModelWorkingDirectory = 'model_working_directory';
  // Android-only: the SAF tree URI backing the user-selected
  // working directory. iOS / desktop don't need it (iOS uses
  // the app sandbox via `dart:io`; desktop uses the working
  // directory path directly). Persisted by the native side too
  // (FileBridge writes to `agent_buddy_prefs` on every
  // re-authorization), so this key mirrors that value.
  static const _kModelWorkingTreeUri = 'model_working_tree_uri';
  static const _kThinkingModeEnabled = 'thinking_mode_enabled';
  // Desktop-only: persisted toggle for "launch at login / auto-start".
  // Ignored on mobile / web — the general settings UI only renders
  // the switch on desktop platforms, but the key still lives in
  // SharedPreferences so the value survives a reinstall / cross-
  // platform dev build (rare but possible).
  static const _kAutoStartEnabled = 'auto_start_enabled';
  // Desktop-only: master switch that decides whether the desktop
  // pet window is shown. Mirrors the top-level switch on the pet
  // tab. Persisted so a cold start re-launches the pet window when
  // the user expects it.
  static const _kShowDesktopPet = 'show_desktop_pet';
  // Id of the currently selected pet (`builtin:anya` for the
  // bundled one, or a user-imported id). Persisted so the same
  // pet re-appears after a restart.
  static const _kActivePetId = 'active_pet_id';

  late final SharedPreferences _prefs;
  final ChatSessionRepository _sessions = ChatSessionRepository();
  final _uuid = const Uuid();

  /// Repository for chat sessions. Lazily opened during [init].
  ChatSessionRepository get sessions => _sessions;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _sessions.open();
    await _migrateLegacyMessages();
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

  /// Master switch for the whole tool subsystem. When false, the
  /// model sees no tool schemas and the system prompt skips all
  /// tool-related guidance, so a "pure chat" turn costs only the
  /// regular prompt + completion tokens. Defaults to true so
  /// existing installs keep their current behaviour.
  bool get toolsEnabled => _prefs.getBool(_kToolsEnabled) ?? true;
  Future<void> setToolsEnabled(bool value) async {
    await _prefs.setBool(_kToolsEnabled, value);
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

  // MCP Providers
  List<McpProvider> loadMcpProviders() {
    final raw = _prefs.getStringList(_kMcpProviders) ?? const [];
    return raw.map((e) => McpProvider.fromRawJson(e)).toList();
  }

  Future<void> saveMcpProviders(List<McpProvider> providers) async {
    final raw = providers.map((e) => e.toRawJson()).toList();
    await _prefs.setStringList(_kMcpProviders, raw);
  }

  List<String> get activeMcpIds =>
      _prefs.getStringList(_kActiveMcpIds) ?? const [];
  Future<void> setActiveMcpIds(List<String> ids) async {
    await _prefs.setStringList(_kActiveMcpIds, ids);
  }

  // Messages
  //
  // The chat-history surface has been replaced by a per-session
  // model persisted via [ChatSessionRepository]. The legacy
  // SharedPreferences list at [kLegacyMessages] is migrated to a
  // single "default" session on first launch (see [_migrateLegacyMessages]).

  // Active session tracking (the conversation the user is currently
  // looking at). Empty string means "no session selected" — the UI
  // should auto-select the most recent one.
  String? get activeSessionId => _prefs.getString(_kActiveSessionId);
  Future<void> setActiveSessionId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(_kActiveSessionId);
    } else {
      await _prefs.setString(_kActiveSessionId, id);
    }
  }

  /// One-time migration: if the user upgraded from the
  // pre-session build, their `chat_messages` list is converted into
  // a single ChatSession named "Imported chat". Subsequent app
  // starts skip this.
  Future<void> _migrateLegacyMessages() async {
    final raw = _prefs.getString(_kLegacyMessages);
    if (raw == null || raw.isEmpty) return;
    if (_sessions.length > 0) {
      // Already migrated (or the user has at least one session).
      // Clean up the legacy key and exit.
      await _prefs.remove(_kLegacyMessages);
      return;
    }
    try {
      final list = jsonDecode(raw) as List;
      final messages = list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
      if (messages.isEmpty) {
        await _prefs.remove(_kLegacyMessages);
        return;
      }
      final firstUser = messages.firstWhere(
        (m) => m.role == MessageRole.user,
        orElse: () => messages.first,
      );
      final now = DateTime.now();
      final session = ChatSession(
        id: _uuid.v4(),
        title: ChatSession.deriveTitle(firstUser.content),
        createdAt: messages.isNotEmpty ? messages.first.createdAt : now,
        updatedAt: messages.isNotEmpty ? messages.last.createdAt : now,
        messages: List<ChatMessage>.unmodifiable(messages),
      );
      await _sessions.save(session);
      await _prefs.setString(_kActiveSessionId, session.id);
    } catch (_) {
      // Migration is best-effort; if the legacy blob is corrupt we
      // just drop it and start fresh.
    } finally {
      await _prefs.remove(_kLegacyMessages);
    }
  }

  // Theme
  String get themeMode => _prefs.getString(_kThemeMode) ?? 'system';
  Future<void> setThemeMode(String mode) async {
    await _prefs.setString(_kThemeMode, mode);
  }

  // Locale
  String get localeCode => _prefs.getString(_kLocaleCode) ?? 'system';
  Future<void> setLocaleCode(String code) async {
    await _prefs.setString(_kLocaleCode, code);
  }

  // Google Sheet
  GoogleSheetConfig loadGoogleSheetConfig() {
    final raw = _prefs.getString(_kGoogleSheetConfig);
    if (raw == null || raw.isEmpty) return GoogleSheetConfig.empty;
    try {
      return GoogleSheetConfig.fromRawJson(raw);
    } catch (_) {
      return GoogleSheetConfig.empty;
    }
  }

  Future<void> saveGoogleSheetConfig(GoogleSheetConfig config) async {
    await _prefs.setString(_kGoogleSheetConfig, config.toRawJson());
  }

  String? get modelWorkingDirectory =>
      _prefs.getString(_kModelWorkingDirectory);

  Future<void> setModelWorkingDirectory(String? path) async {
    if (path == null || path.trim().isEmpty) {
      await _prefs.remove(_kModelWorkingDirectory);
    } else {
      await _prefs.setString(_kModelWorkingDirectory, path.trim());
    }
  }

  /// Android-only: the SAF `content://` tree URI backing the
  /// user-selected working directory. `null` when no working
  /// directory is selected or on non-Android platforms.
  ///
  /// The native bridge also writes this key (see
  /// `FileBridge.saveWorkingDirectory` in
  /// `android/app/.../FileBridge.kt`) every time the user
  /// re-authorizes the working directory, so the two layers
  /// stay in sync.
  String? get modelWorkingTreeUri => _prefs.getString(_kModelWorkingTreeUri);

  Future<void> setModelWorkingTreeUri(String? uri) async {
    if (uri == null || uri.isEmpty) {
      await _prefs.remove(_kModelWorkingTreeUri);
    } else {
      await _prefs.setString(_kModelWorkingTreeUri, uri);
    }
  }

  bool get thinkingModeEnabled =>
      _prefs.getBool(_kThinkingModeEnabled) ?? false;

  Future<void> setThinkingModeEnabled(bool enabled) async {
    await _prefs.setBool(_kThinkingModeEnabled, enabled);
  }

  /// Desktop-only: persisted "launch at login" toggle. Defaults to
  /// `false` so a fresh install doesn't surprise the user with an
  /// OS-level startup hook the app quietly installed.
  bool get autoStartEnabled => _prefs.getBool(_kAutoStartEnabled) ?? false;

  Future<void> setAutoStartEnabled(bool enabled) async {
    await _prefs.setBool(_kAutoStartEnabled, enabled);
  }

  /// Master switch for the desktop pet window. Defaults to `false`
  /// so a fresh install doesn't pop up a transparent window until
  /// the user opts in on the pet tab. Survives restarts.
  bool get showDesktopPet => _prefs.getBool(_kShowDesktopPet) ?? false;

  Future<void> setShowDesktopPet(bool enabled) async {
    await _prefs.setBool(_kShowDesktopPet, enabled);
  }

  /// Id of the pet the user has selected on the pet tab. `null`
  /// means "no pet chosen yet" — the provider falls back to the
  /// bundled Anya when the toggle is flipped on without an explicit
  /// pick.
  String? get activePetId => _prefs.getString(_kActivePetId);

  Future<void> setActivePetId(String? id) async {
    if (id == null || id.isEmpty) {
      await _prefs.remove(_kActivePetId);
    } else {
      await _prefs.setString(_kActivePetId, id);
    }
  }
}
