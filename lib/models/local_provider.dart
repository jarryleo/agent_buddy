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

  /// Quantization for the K half of the KV cache. `q8_0` ≈ 0.5× the memory
  /// of `f16`; `q4_0` ≈ 0.25×. Non-f16 requires flash attention.
  final String cacheTypeK;

  /// Quantization for the V half of the KV cache.
  final String cacheTypeV;

  /// Logical batch size passed to llama.cpp as `n_batch`. This is the
  /// size of the per-step compute buffer (input embeddings, attention
  /// mask, logits over the full vocabulary, ...). The default of
  /// [kDefaultBatchSize] is what llama.cpp's `main` example, Ollama
  /// and LM Studio use for chat. Setting it to `contextSize` (the
  /// llama.cpp default when unset) can blow past available RAM/VRAM
  /// for any context window above ~8K — the logits buffer alone
  /// scales as `n_batch × vocab_size × 4` and a 256K-vocab model at
  /// n_batch=32K needs 32 GB just for logits.
  final int batchSize;

  /// Safe interactive-chat default for [batchSize]. Matches llama.cpp
  /// `main`, Ollama, and LM Studio.
  static const int kDefaultBatchSize = 512;

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
    this.cacheTypeK = 'f16',
    this.cacheTypeV = 'f16',
    this.batchSize = kDefaultBatchSize,
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
    String? cacheTypeK,
    String? cacheTypeV,
    int? batchSize,
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
      cacheTypeK: cacheTypeK ?? this.cacheTypeK,
      cacheTypeV: cacheTypeV ?? this.cacheTypeV,
      batchSize: batchSize ?? this.batchSize,
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
    'cacheTypeK': cacheTypeK,
    'cacheTypeV': cacheTypeV,
    'batchSize': batchSize,
    'createdAt': createdAt.toIso8601String(),
  };

  factory LocalProvider.fromJson(Map<String, dynamic> json) {
    final rawBatch = (json['batchSize'] as num?)?.toInt() ?? 0;
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
      cacheTypeK: _normalizeCacheType(json['cacheTypeK']) ?? 'f16',
      cacheTypeV: _normalizeCacheType(json['cacheTypeV']) ?? 'f16',
      // Missing or zero falls back to the safe default. Stored `0` from
      // an older app version used to mean "= n_ctx" in llama.cpp,
      // which is the actual bug we're fixing, so we never honour it.
      batchSize: rawBatch > 0 ? rawBatch : kDefaultBatchSize,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static String? _normalizeCacheType(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'f16':
      case 'q8_0':
      case 'q4_0':
        return raw;
      default:
        return null;
    }
  }

  String toRawJson() => jsonEncode(toJson());
  factory LocalProvider.fromRawJson(String raw) =>
      LocalProvider.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
