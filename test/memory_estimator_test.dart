import 'package:agent_buddy/services/gguf_metadata.dart';
import 'package:agent_buddy/services/memory_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryEstimator', () {
    const gemma3_4b = ModelArchitecture(
      embeddingLength: 2560,
      blockCount: 26,
      headCountKv: 4,
      keyLength: 256,
      valueLength: 256,
      vocabSize: 256000,
      contextLength: 131072,
    );

    test('f16 KV cache scales linearly with context size', () {
      const est = MemoryEstimator();
      final at4k = est.estimateKvCacheBytes(
        arch: gemma3_4b,
        contextSize: 4096,
        cacheTypeK: 'f16',
        cacheTypeV: 'f16',
      );
      final at32k = est.estimateKvCacheBytes(
        arch: gemma3_4b,
        contextSize: 32768,
        cacheTypeK: 'f16',
        cacheTypeV: 'f16',
      );
      // 8x context → 8x KV bytes (linear).
      expect(at32k, at4k * 8);
    });

    test('q8_0 KV cache is roughly half of f16', () {
      const est = MemoryEstimator();
      final f16 = est.estimateKvCacheBytes(
        arch: gemma3_4b,
        contextSize: 32768,
        cacheTypeK: 'f16',
        cacheTypeV: 'f16',
      );
      final q8 = est.estimateKvCacheBytes(
        arch: gemma3_4b,
        contextSize: 32768,
        cacheTypeK: 'q8_0',
        cacheTypeV: 'q8_0',
      );
      // q8_0 ≈ 0.5× f16; allow 60% upper bound for block overhead.
      expect(q8, lessThan(f16 ~/ 2 + f16 ~/ 10));
      expect(q8, greaterThan(f16 * 4 ~/ 10));
    });

    test('q4_0 KV cache is roughly a quarter of f16', () {
      const est = MemoryEstimator();
      final f16 = est.estimateKvCacheBytes(
        arch: gemma3_4b,
        contextSize: 32768,
        cacheTypeK: 'f16',
        cacheTypeV: 'f16',
      );
      final q4 = est.estimateKvCacheBytes(
        arch: gemma3_4b,
        contextSize: 32768,
        cacheTypeK: 'q4_0',
        cacheTypeV: 'q4_0',
      );
      expect(q4, lessThan(f16 ~/ 4 + f16 ~/ 10));
      expect(q4, greaterThan(f16 * 2 ~/ 10));
    });

    test('compute buffer scales linearly with batch size', () {
      const est = MemoryEstimator();
      final at512 = est.estimateComputeBufferBytes(
        batchSize: 512,
        vocabSize: 256000,
        hiddenSize: 2560,
      );
      final at2048 = est.estimateComputeBufferBytes(
        batchSize: 2048,
        vocabSize: 256000,
        hiddenSize: 2560,
      );
      // Logits dominate: 256K × 4 × n_batch.
      // at512: 512 × 256000 × 4 ≈ 500 MB
      // at2048: 2048 × 256000 × 4 ≈ 2 GB
      expect(at2048, greaterThan(at512 * 3));
      expect(at2048, lessThan(at512 * 5));
    });

    test('returns 0 KV cache bytes when architecture is missing', () {
      const est = MemoryEstimator();
      final bytes = est.estimateKvCacheBytes(
        arch: null,
        contextSize: 32768,
        cacheTypeK: 'q4_0',
        cacheTypeV: 'q4_0',
      );
      expect(bytes, 0);
    });

    test('heuristic KV cache scales with file size', () {
      const est = MemoryEstimator();
      final small = est.estimateKvCacheBytesHeuristic(
        modelFileBytes: 2 * 1024 * 1024 * 1024,
        contextSize: 32768,
        cacheTypeK: 'f16',
        cacheTypeV: 'f16',
      );
      final big = est.estimateKvCacheBytesHeuristic(
        modelFileBytes: 8 * 1024 * 1024 * 1024,
        contextSize: 32768,
        cacheTypeK: 'f16',
        cacheTypeV: 'f16',
      );
      // 4× file size → roughly 4× KV cache. Allow some float-rounding
      // slop: 3.5×..4.5×.
      final ratio = big / small;
      expect(ratio, greaterThan(3.5));
      expect(ratio, lessThan(4.5));
    });

    test('full breakdown adds up (model + kv + compute + flash)', () {
      const est = MemoryEstimator();
      final bd = est.estimate(
        modelFileBytes: 4 * 1024 * 1024 * 1024,
        arch: gemma3_4b,
        contextSize: 32768,
        batchSize: 512,
        cacheTypeK: 'q4_0',
        cacheTypeV: 'q4_0',
      );
      // 4B Q8_K model at 32K q4_0 + 512 batch should be under 10 GB.
      expect(bd.kvCacheBytes, greaterThan(0));
      expect(bd.computeBufferBytes, greaterThan(100 * 1024 * 1024));
      expect(bd.totalBytes, lessThan(10 * 1024 * 1024 * 1024));
      expect(
        bd.totalBytes,
        greaterThanOrEqualTo(bd.modelFileBytes + bd.kvCacheBytes),
      );
    });

    test('formatBytes picks sensible units', () {
      expect(formatBytes(500), '500 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2.0 GB');
    });
  });
}
