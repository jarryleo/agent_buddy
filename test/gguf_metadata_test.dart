import 'dart:io';
import 'dart:typed_data';

import 'package:agent_buddy/services/gguf_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GgufMetadataReader', () {
    test('returns null for missing files', () async {
      final reader = const GgufMetadataReader();
      final result = await reader.read(
        'D:/this/path/does/not/exist.gguf',
      );
      expect(result, isNull);
    });

    test('returns null for a file without the GGUF magic', () async {
      final dir = await Directory.systemTemp.createTemp('gguf_test_');
      final path = '${dir.path}/bad.gguf';
      final f = File(path);
      await f.writeAsBytes([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
      try {
        final reader = const GgufMetadataReader();
        final result = await reader.read(path);
        expect(result, isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('parses a minimal llama-shaped GGUF header', () async {
      final dir = await Directory.systemTemp.createTemp('gguf_test_');
      final path = '${dir.path}/good.gguf';
      final f = File(path);
      await f.writeAsBytes(_buildMinimalGguf(
        version: 3,
        kv: [
          _Kv('llama.embedding_length', 4, _u32(2560)),
          _Kv('llama.block_count', 4, _u32(26)),
          _Kv('llama.attention.head_count_kv', 4, _u32(8)),
          _Kv('llama.attention.key_length', 4, _u32(256)),
          _Kv('llama.attention.value_length', 4, _u32(256)),
          _Kv('llama.vocab_size', 4, _u32(256000)),
          _Kv('llama.context_length', 4, _u32(131072)),
        ],
      ));
      try {
        final reader = const GgufMetadataReader();
        final result = await reader.read(path);
        expect(result, isNotNull);
        expect(result!.embeddingLength, 2560);
        expect(result.blockCount, 26);
        expect(result.headCountKv, 8);
        expect(result.keyLength, 256);
        expect(result.valueLength, 256);
        expect(result.vocabSize, 256000);
        expect(result.contextLength, 131072);
        expect(result.headDim, 256);
        expect(result.canEstimateKv, isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('matches keys across architectures (gemma3 prefix)', () async {
      final dir = await Directory.systemTemp.createTemp('gguf_test_');
      final path = '${dir.path}/gemma.gguf';
      final f = File(path);
      await f.writeAsBytes(_buildMinimalGguf(
        version: 3,
        kv: [
          _Kv('gemma3.embedding_length', 4, _u32(2560)),
          _Kv('gemma3.block_count', 4, _u32(26)),
          _Kv('gemma3.attention.head_count_kv', 4, _u32(4)),
          _Kv('gemma3.attention.key_length', 4, _u32(256)),
        ],
      ));
      try {
        final reader = const GgufMetadataReader();
        final result = await reader.read(path);
        expect(result, isNotNull);
        expect(result!.embeddingLength, 2560);
        expect(result.blockCount, 26);
        expect(result.headCountKv, 4);
        expect(result.keyLength, 256);
        expect(result.headDim, 256);
        expect(result.canEstimateKv, isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('returns partial architecture when keys are missing', () async {
      final dir = await Directory.systemTemp.createTemp('gguf_test_');
      final path = '${dir.path}/partial.gguf';
      final f = File(path);
      await f.writeAsBytes(_buildMinimalGguf(
        version: 3,
        kv: [
          _Kv('llama.embedding_length', 4, _u32(4096)),
        ],
      ));
      try {
        final reader = const GgufMetadataReader();
        final result = await reader.read(path);
        expect(result, isNotNull);
        expect(result!.embeddingLength, 4096);
        expect(result.blockCount, isNull);
        expect(result.canEstimateKv, isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('skips unknown string and array KV entries safely', () async {
      final dir = await Directory.systemTemp.createTemp('gguf_test_');
      final path = '${dir.path}/noisy.gguf';
      final f = File(path);
      // Put an unknown STRING KV (llama.name) BEFORE the
      // block_count entry, so the parser has to skip it first.
      await f.writeAsBytes(_buildMinimalGguf(
        version: 3,
        kv: [
          _Kv('llama.name', 8, _string('Tiny Test Model')),
          _Kv('llama.block_count', 4, _u32(12)),
        ],
      ));
      try {
        final reader = const GgufMetadataReader();
        final result = await reader.read(path);
        expect(result, isNotNull);
        expect(result!.blockCount, 12);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

class _Kv {
  const _Kv(this.key, this.type, this.value);
  final String key;
  final int type;
  final Uint8List value;
}

Uint8List _u32(int v) {
  final bd = ByteData(4)..setUint32(0, v, Endian.little);
  return bd.buffer.asUint8List();
}

Uint8List _string(String s) {
  final bytes = Uint8List.fromList(s.codeUnits);
  final out = BytesBuilder()
    ..add(_u64(bytes.length))
    ..add(bytes);
  return out.toBytes();
}

Uint8List _u64(int v) {
  final bd = ByteData(8)..setUint64(0, v, Endian.little);
  return bd.buffer.asUint8List();
}

Uint8List _buildMinimalGguf({
  required int version,
  required List<_Kv> kv,
}) {
  // Header: magic(4) + version(4) + tensor_count(8) + kv_count(8)
  final builder = BytesBuilder();
  builder.add([0x47, 0x47, 0x55, 0x46]); // GGUF
  builder.add(_u32(version));
  builder.add(_u64(0)); // tensor_count (irrelevant — we stop at KV block)
  builder.add(_u64(kv.length));
  for (final entry in kv) {
    final keyBytes = Uint8List.fromList(entry.key.codeUnits);
    builder.add(_u64(keyBytes.length));
    builder.add(keyBytes);
    builder.add(_u32(entry.type));
    builder.add(entry.value);
  }
  return builder.toBytes();
}
