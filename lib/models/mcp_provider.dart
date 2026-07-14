import 'dart:convert';

class McpToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  McpToolDef({
    required this.name,
    this.description = '',
    Map<String, dynamic>? inputSchema,
  }) : inputSchema = inputSchema ?? {};

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };

  factory McpToolDef.fromJson(Map<String, dynamic> json) => McpToolDef(
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    inputSchema: json['inputSchema'] is Map
        ? Map<String, dynamic>.from(json['inputSchema'] as Map)
        : null,
  );
}

enum McpTransportType { http, stdio }

class McpProvider {
  final String id;
  final String name;
  final String jsonConfig;
  final bool enabled;
  final DateTime createdAt;

  McpProvider({
    required this.id,
    required this.name,
    required this.jsonConfig,
    this.enabled = true,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  McpProvider copyWith({String? name, String? jsonConfig, bool? enabled}) {
    return McpProvider(
      id: id,
      name: name ?? this.name,
      jsonConfig: jsonConfig ?? this.jsonConfig,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> get _parsed {
    try {
      final trimmed = jsonConfig.trim();
      if (trimmed.startsWith('{')) {
        final parsed = jsonDecode(trimmed) as Map<String, dynamic>;

        // Handle mcpServers wrapper: { "mcpServers": { "name": { ... } } }
        if (parsed.containsKey('mcpServers')) {
          final servers = parsed['mcpServers'] as Map<String, dynamic>? ?? {};
          if (servers.isNotEmpty) {
            final entry = servers.entries.first;
            return entry.value is Map
                ? Map<String, dynamic>.from(entry.value as Map)
                : parsed;
          }
        }
        return parsed;
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  McpTransportType get transportType {
    final p = _parsed;
    if (p.containsKey('command')) return McpTransportType.stdio;
    if (p.containsKey('url')) return McpTransportType.http;
    // Plain URL string
    if (jsonConfig.trim().startsWith('http')) return McpTransportType.http;
    return McpTransportType.stdio;
  }

  String get serverUrl {
    final p = _parsed;
    if (p case {'url': String url}) return url;
    final trimmed = jsonConfig.trim();
    if (trimmed.startsWith('http')) return trimmed;
    return '';
  }

  Map<String, String> get headers {
    final p = _parsed;
    final h = p['headers'];
    if (h is Map) {
      return (h as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v.toString()),
      );
    }
    return const {};
  }

  String? get command {
    final p = _parsed;
    final cmd = p['command'] as String?;
    if (cmd != null && cmd.isNotEmpty) return cmd;
    return null;
  }

  List<String> get commandArgs {
    final p = _parsed;
    final args = p['args'];
    if (args is List) return args.cast<String>();
    return const [];
  }

  Map<String, String> get commandEnv {
    final p = _parsed;
    final env = p['env'];
    if (env is Map) {
      return (env as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v.toString()),
      );
    }
    return const {};
  }

  /// Human-readable description of the server endpoint/config.
  String get displayInfo {
    switch (transportType) {
      case McpTransportType.http:
        return serverUrl;
      case McpTransportType.stdio:
        final cmd = command ?? '';
        return '$cmd ${commandArgs.take(3).join(' ')}';
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'jsonConfig': jsonConfig,
    'enabled': enabled,
    'createdAt': createdAt.toIso8601String(),
  };

  factory McpProvider.fromJson(Map<String, dynamic> json) => McpProvider(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'MCP',
    jsonConfig: json['jsonConfig'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    createdAt: json['createdAt'] != null
        ? DateTime.parse(json['createdAt'] as String)
        : null,
  );

  String toRawJson() => jsonEncode(toJson());
  factory McpProvider.fromRawJson(String raw) =>
      McpProvider.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
