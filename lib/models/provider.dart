import 'dart:convert';

import 'file_type.dart';

enum ProviderProtocol { openai, anthropic }

extension ProviderProtocolX on ProviderProtocol {
  String get label {
    switch (this) {
      case ProviderProtocol.openai:
        return 'OpenAI';
      case ProviderProtocol.anthropic:
        return 'Anthropic';
    }
  }

  String get defaultPath {
    switch (this) {
      case ProviderProtocol.openai:
        return '/v1/chat/completions';
      case ProviderProtocol.anthropic:
        return '/v1/messages';
    }
  }

  String get defaultBaseUrl {
    switch (this) {
      case ProviderProtocol.openai:
        return 'https://api.openai.com';
      case ProviderProtocol.anthropic:
        return 'https://api.anthropic.com';
    }
  }

  String get defaultModelsPath {
    switch (this) {
      case ProviderProtocol.openai:
        return '/v1/models';
      case ProviderProtocol.anthropic:
        return '/v1/models';
    }
  }
}

/// Subset of [AgentFileType] that newly-created cloud providers
/// default to.
///
/// `text` is always on and is the only category the settings UI
/// pins — the wire layer never inlines text bodies (it always
/// forwards `<attached_file path="…" />` and lets the model pull
/// the file via the file tool), so the toggle is purely
/// cosmetic. We still surface it as a checked-by-default chip so
/// the user can see that the model knows about text files.
///
/// `image` is the only category that's historically inlined
/// (OpenAI's `image_url` / Anthropic's image parts). Other
/// categories (`audio`, `video`, `document`) opt in to file_data
/// / document parts when the user enables them; users opt in per
/// provider via the Add/Edit screen.
const Set<AgentFileType> kDefaultSupportedFileTypes = {
  AgentFileType.text,
  AgentFileType.image,
};

class ModelProvider {
  final String id;
  final String name;
  final ProviderProtocol protocol;
  final String baseUrl;
  final String apiKey;
  final String chatPath;
  final List<String> models;
  final bool enabled;
  final String? selectedModel;
  final DateTime createdAt;

  /// File categories the model accepts as inline base64. Files
  /// whose category isn't in this set are forwarded to the model
  /// as path-only references (`<attached_file path="…" />`) so the
  /// model can pull them through the `file` tool. `null` is
  /// tolerated on read for backward compatibility with rows
  /// persisted before this field existed — those rows fall back
  /// to the image-only default so today's behavior is unchanged.
  final Set<AgentFileType>? supportedFileTypes;

  /// Whether to attach Anthropic-style `cache_control` blocks to
  /// the wire payload when the active protocol supports it.
  ///
  /// Off by default so legacy OpenAI-compatible providers (which
  /// silently drop unknown fields) keep behaving the same. When
  /// the provider points at the MiniMax Anthropic-compatible
  /// endpoint (or any other Anthropic-protocol gateway that has
  /// prompt caching enabled), flipping this on instructs
  /// `ApiService` to tag the last tool definition, the last
  /// system block, and the last user-message block with
  /// `{"type": "ephemeral"}` — see
  /// https://platform.minimaxi.com/docs/api-reference/anthropic-api-compatible-cache.
  ///
  /// Cost/latency tradeoff:
  ///   * First request — small extra cost (the cache-control
  ///     markers themselves are tiny; the cached content is
  ///     written once at "cache write" pricing).
  ///   * Subsequent requests inside the 5-minute TTL — much lower
  ///     per-token cost ("cache read" pricing ≈ 5x cheaper than
  ///     regular input) and noticeably faster TTFT.
  ///   * Outside the 5-minute TTL — first request cost again.
  ///
  /// No-op for the OpenAI / local paths; the wire layer only
  /// honours it on the Anthropic protocol.
  final bool promptCacheEnabled;

  ModelProvider({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
    required this.chatPath,
    this.models = const [],
    this.enabled = true,
    this.selectedModel,
    this.supportedFileTypes,
    this.promptCacheEnabled = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Resolved view of [supportedFileTypes] — falls back to the
  /// image-only default when the persisted set is missing, so
  /// older rows keep working unchanged. An empty set is
  /// intentionally *not* treated as "missing" — that's the user
  /// explicitly clearing every category (path-only mode for
  /// every attachment).
  Set<AgentFileType> get effectiveSupportedFileTypes {
    final s = supportedFileTypes;
    if (s == null) return kDefaultSupportedFileTypes;
    return s;
  }

  String get fullChatUrl {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final path = chatPath.startsWith('/') ? chatPath : '/$chatPath';
    return '$base$path';
  }

  ModelProvider copyWith({
    String? name,
    ProviderProtocol? protocol,
    String? baseUrl,
    String? apiKey,
    String? chatPath,
    List<String>? models,
    bool? enabled,
    String? selectedModel,
    Object? supportedFileTypes = _sentinel,
    bool? promptCacheEnabled,
  }) {
    return ModelProvider(
      id: id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      chatPath: chatPath ?? this.chatPath,
      models: models ?? this.models,
      enabled: enabled ?? this.enabled,
      selectedModel: selectedModel ?? this.selectedModel,
      supportedFileTypes: identical(supportedFileTypes, _sentinel)
          ? this.supportedFileTypes
          : supportedFileTypes as Set<AgentFileType>?,
      promptCacheEnabled: promptCacheEnabled ?? this.promptCacheEnabled,
      createdAt: createdAt,
    );
  }

  /// Sentinel used by [copyWith] to distinguish "argument omitted"
  /// from "argument explicitly passed as null". Required for
  /// [supportedFileTypes] because `Set<AgentFileType>?` collapses
  /// `null` (clear) and "absent" (keep) without a sentinel.
  static const Object _sentinel = Object();

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'chatPath': chatPath,
    'models': models,
    'enabled': enabled,
    'selectedModel': selectedModel,
    // Persist as a sorted list of enum names so the JSON stays
    // stable across Dart enum reordering. Drop the key entirely
    // when the set is the default (`null`); the loader falls back
    // to the image-only default in that case.
    if (supportedFileTypes != null)
      'supportedFileTypes':
          (supportedFileTypes!.toList()
                ..sort((a, b) => a.index.compareTo(b.index)))
              .map((e) => e.name)
              .toList(),
    // Only serialize when true so v1 records (no
    // `promptCacheEnabled` key) round-trip identically. Default
    // on read is `false`.
    if (promptCacheEnabled) 'promptCacheEnabled': true,
    'createdAt': createdAt.toIso8601String(),
  };

  factory ModelProvider.fromJson(Map<String, dynamic> json) {
    final rawTypes = json['supportedFileTypes'] as List?;
    Set<AgentFileType>? parsed;
    if (rawTypes != null) {
      parsed = <AgentFileType>{};
      for (final raw in rawTypes) {
        if (raw is! String) continue;
        for (final t in AgentFileType.values) {
          if (t.name == raw) {
            parsed.add(t);
            break;
          }
        }
      }
      // Empty list == "user explicitly cleared everything" — keep
      // it as an empty set so the wire logic sees "no inline
      // categories enabled" rather than falling back to the
      // default. Only `null` triggers the default.
      if (parsed.isEmpty) parsed = <AgentFileType>{};
    }
    return ModelProvider(
      id: json['id'] as String,
      name: json['name'] as String,
      protocol: ProviderProtocol.values.firstWhere(
        (e) => e.name == json['protocol'],
        orElse: () => ProviderProtocol.openai,
      ),
      baseUrl: json['baseUrl'] as String,
      apiKey: json['apiKey'] as String? ?? '',
      chatPath:
          json['chatPath'] as String? ?? ProviderProtocol.openai.defaultPath,
      models: (json['models'] as List?)?.cast<String>() ?? const [],
      enabled: json['enabled'] as bool? ?? true,
      selectedModel: json['selectedModel'] as String?,
      supportedFileTypes: parsed,
      promptCacheEnabled: json['promptCacheEnabled'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory ModelProvider.fromRawJson(String raw) =>
      ModelProvider.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
