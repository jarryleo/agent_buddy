import 'dart:convert';

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
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

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
      createdAt: createdAt,
    );
  }

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
    'createdAt': createdAt.toIso8601String(),
  };

  factory ModelProvider.fromJson(Map<String, dynamic> json) {
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
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory ModelProvider.fromRawJson(String raw) =>
      ModelProvider.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
