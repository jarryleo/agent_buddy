import 'dart:convert';

class LocalProvider {
  final String id;
  final String name;
  final String modelPath;
  final String? mmprojPath;
  final int contextSize;
  final double temperature;
  final int gpuLayers;
  final int maxTokens;
  final bool enabled;
  final DateTime createdAt;

  LocalProvider({
    required this.id,
    required this.name,
    required this.modelPath,
    this.mmprojPath,
    this.contextSize = 4096,
    this.temperature = 0.7,
    this.gpuLayers = 0,
    this.maxTokens = 1024,
    this.enabled = true,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  LocalProvider copyWith({
    String? name,
    String? modelPath,
    String? mmprojPath,
    int? contextSize,
    double? temperature,
    int? gpuLayers,
    int? maxTokens,
    bool? enabled,
  }) {
    return LocalProvider(
      id: id,
      name: name ?? this.name,
      modelPath: modelPath ?? this.modelPath,
      mmprojPath: mmprojPath ?? this.mmprojPath,
      contextSize: contextSize ?? this.contextSize,
      temperature: temperature ?? this.temperature,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      maxTokens: maxTokens ?? this.maxTokens,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
    );
  }

  String get displayModelName {
    final name = modelPath.split(RegExp(r'[\\/]')).last;
    return name.isEmpty ? modelPath : name;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'modelPath': modelPath,
    'mmprojPath': mmprojPath,
    'contextSize': contextSize,
    'temperature': temperature,
    'gpuLayers': gpuLayers,
    'maxTokens': maxTokens,
    'enabled': enabled,
    'createdAt': createdAt.toIso8601String(),
  };

  factory LocalProvider.fromJson(Map<String, dynamic> json) {
    return LocalProvider(
      id: json['id'] as String,
      name: json['name'] as String,
      modelPath: json['modelPath'] as String,
      mmprojPath: json['mmprojPath'] as String?,
      contextSize: (json['contextSize'] as num?)?.toInt() ?? 4096,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      gpuLayers: (json['gpuLayers'] as num?)?.toInt() ?? 0,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 1024,
      enabled: json['enabled'] as bool? ?? true,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory LocalProvider.fromRawJson(String raw) =>
      LocalProvider.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
