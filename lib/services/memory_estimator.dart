import 'gguf_metadata.dart';

/// Per-component memory estimate. All bytes are bytes (not MiB/GiB);
/// formatting is the UI's job.
class MemoryBreakdown {
  const MemoryBreakdown({
    required this.modelFileBytes,
    required this.kvCacheBytes,
    required this.computeBufferBytes,
    required this.flashAttentionBytes,
    required this.totalBytes,
  });

  /// Bytes for the on-disk model file. mmap means only active pages
  /// sit in physical RAM, but for the user's mental model the whole
  /// file is what they need to "have room for".
  final int modelFileBytes;

  /// KV cache: 2 (K+V) × n_layers × n_kv_heads × context_size ×
  /// bytes_per_element.
  final int kvCacheBytes;

  /// llama.cpp's per-step compute buffers: logits over the full
  /// vocabulary, input embeddings, attention mask, etc. Scales
  /// linearly with n_batch.
  final int computeBufferBytes;

  /// Flash attention scratch (V cache transposed, KQ accumulators,
  /// ...). Scales with n_batch × n_layers × n_kv_heads × head_dim.
  final int flashAttentionBytes;

  final int totalBytes;
}

/// Heuristic + arch-aware memory estimator for "if I load this model
/// with these settings, how much memory will it eat?".
///
/// The numbers are deliberately conservative (round up). A few MB of
/// slack here costs the user nothing; under-estimating makes them
/// hit the "Failed to create context" wall again.
class MemoryEstimator {
  const MemoryEstimator();

  /// Bytes per KV cache element, by type. The values match llama.cpp's
  /// own per-element storage costs (F16 = 2 B, Q8_0 block-quantized
  /// is ~1 B on average, Q4_0 is ~0.5 B with block overhead).
  static double bytesPerKvElement(String cacheType) {
    switch (cacheType) {
      case 'q8_0':
        return 1.0;
      case 'q4_0':
        return 0.5;
      case 'f16':
      default:
        return 2.0;
    }
  }

  /// Estimate the KV cache footprint for the given context size.
  /// Returns 0 if architecture is missing.
  int estimateKvCacheBytes({
    required ModelArchitecture? arch,
    required int contextSize,
    required String cacheTypeK,
    required String cacheTypeV,
  }) {
    if (arch == null || !arch.canEstimateKv) return 0;
    final layers = arch.blockCount!;
    final kvHeads = arch.headCountKv!;
    final keyLen = arch.keyLength ?? arch.headDim!;
    final valLen = arch.valueLength ?? arch.headDim!;
    final bytesK = bytesPerKvElement(cacheTypeK);
    final bytesV = bytesPerKvElement(cacheTypeV);
    return (contextSize *
            layers *
            kvHeads *
            (keyLen * bytesK + valLen * bytesV))
        .round();
  }

  /// llama.cpp's compute buffers. Two big ones:
  /// - logits: n_batch × vocab_size × 4 (float32). This is the
  ///   silent killer at 32K+ context if batch isn't bounded.
  /// - inp_embd: n_batch × hidden_size × 4
  /// Plus the attention mask (n_batch × n_batch × 4) and a small
  /// pile of scratch.
  int estimateComputeBufferBytes({
    required int batchSize,
    required int? vocabSize,
    required int? hiddenSize,
  }) {
    final v = vocabSize ?? _fallbackVocabSize;
    final h = hiddenSize ?? _fallbackHiddenSize;
    final logits = batchSize * v * 4;
    final embd = batchSize * h * 4;
    final mask = batchSize * batchSize * 4;
    final scratch = 16 * 1024 * 1024; // ~16 MB misc
    return logits + embd + mask + scratch;
  }

  /// Flash attention workspace. Rough order-of-magnitude.
  int estimateFlashAttentionBytes({
    required ModelArchitecture? arch,
    required int batchSize,
  }) {
    if (arch == null) return 0;
    final layers = arch.blockCount ?? 0;
    final kvHeads = arch.headCountKv ?? 0;
    final headDim = arch.headDim ?? 0;
    // V cache transposed + KQ accumulators + softmax stats.
    return batchSize * layers * kvHeads * headDim * 8;
  }

  /// Rough file-size-based KV cache fallback when architecture is
  /// missing. Anchored at "4 GB Q8_K file ≈ 4B params ≈
  /// ~0.2 MB/token F16" and scales linearly with file size (since
  /// params scale linearly with file size for a given quant).
  int estimateKvCacheBytesHeuristic({
    required int modelFileBytes,
    required int contextSize,
    required String cacheTypeK,
    required String cacheTypeV,
  }) {
    if (modelFileBytes <= 0) return 0;
    final refFile = 4.0 * 1024 * 1024 * 1024; // 4 GB reference
    final refPerTokenF16 = 0.21 * 1024 * 1024; // ~215 KB/token f16 for ~4B
    final scale = modelFileBytes / refFile;
    final perTokenF16 = refPerTokenF16 * scale;
    final bytesK = bytesPerKvElement(cacheTypeK);
    final bytesV = bytesPerKvElement(cacheTypeV);
    return (contextSize * perTokenF16 * (bytesK + bytesV) / 4).round();
  }

  MemoryBreakdown estimate({
    required int modelFileBytes,
    required ModelArchitecture? arch,
    required int contextSize,
    required int batchSize,
    required String cacheTypeK,
    required String cacheTypeV,
  }) {
    int kvBytes = estimateKvCacheBytes(
      arch: arch,
      contextSize: contextSize,
      cacheTypeK: cacheTypeK,
      cacheTypeV: cacheTypeV,
    );
    if (kvBytes == 0) {
      kvBytes = estimateKvCacheBytesHeuristic(
        modelFileBytes: modelFileBytes,
        contextSize: contextSize,
        cacheTypeK: cacheTypeK,
        cacheTypeV: cacheTypeV,
      );
    }
    final computeBytes = estimateComputeBufferBytes(
      batchSize: batchSize,
      vocabSize: arch?.vocabSize,
      hiddenSize: arch?.embeddingLength,
    );
    final flashBytes = estimateFlashAttentionBytes(
      arch: arch,
      batchSize: batchSize,
    );
    // +10% overhead covers tokenizer state, sampler state, and
    // llama.cpp's internal bookkeeping that the above doesn't.
    final overhead =
        ((modelFileBytes + kvBytes + computeBytes + flashBytes) * 0.10).round();
    final total =
        modelFileBytes + kvBytes + computeBytes + flashBytes + overhead;
    return MemoryBreakdown(
      modelFileBytes: modelFileBytes,
      kvCacheBytes: kvBytes,
      computeBufferBytes: computeBytes,
      flashAttentionBytes: flashBytes,
      totalBytes: total,
    );
  }

  /// Fallback arch values for when the GGUF metadata is missing.
  /// Anchored on Gemma 3 4B (vocab 256K, hidden 2560) so the heuristic
  /// at least behaves sanely for "unknown 4B-class" models.
  static const int _fallbackVocabSize = 256000;
  static const int _fallbackHiddenSize = 2560;
}

/// Pretty-print a byte count. Picks the largest unit where the
/// value is ≥ 1, otherwise drops to the next-smaller unit.
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes < 0) return '0 B';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  final absBytes = bytes;
  if (absBytes >= gb) {
    final v = bytes / gb;
    return '${v.toStringAsFixed(decimals)} GB';
  }
  if (absBytes >= mb) {
    final v = bytes / mb;
    return '${v.toStringAsFixed(decimals)} MB';
  }
  if (absBytes >= kb) {
    final v = bytes / kb;
    return '${v.toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
