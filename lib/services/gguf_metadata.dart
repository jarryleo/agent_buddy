import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Architectural fields read from a GGUF v3 file's metadata KV block.
///
/// All fields are nullable because not every quantizer writes every
/// key, and we never want to refuse a file just because one field is
/// missing — we degrade to a file-size heuristic instead.
class ModelArchitecture {
  const ModelArchitecture({
    this.embeddingLength,
    this.blockCount,
    this.headCountKv,
    this.keyLength,
    this.valueLength,
    this.vocabSize,
    this.contextLength,
  });

  final int? embeddingLength;
  final int? blockCount;
  final int? headCountKv;
  final int? keyLength;
  final int? valueLength;
  final int? vocabSize;
  final int? contextLength;

  /// Per-head dimension. Falls back to [valueLength] for models that
  /// only store the V head dim (rare).
  int? get headDim => keyLength ?? valueLength;

  bool get canEstimateKv =>
      blockCount != null && headCountKv != null && headDim != null;

  ModelArchitecture copyWith({
    int? embeddingLength,
    int? blockCount,
    int? headCountKv,
    int? keyLength,
    int? valueLength,
    int? vocabSize,
    int? contextLength,
  }) {
    return ModelArchitecture(
      embeddingLength: embeddingLength ?? this.embeddingLength,
      blockCount: blockCount ?? this.blockCount,
      headCountKv: headCountKv ?? this.headCountKv,
      keyLength: keyLength ?? this.keyLength,
      valueLength: valueLength ?? this.valueLength,
      vocabSize: vocabSize ?? this.vocabSize,
      contextLength: contextLength ?? this.contextLength,
    );
  }
}

/// Lightweight GGUF v3 metadata reader. We don't need the tensor
/// table — just the KV block, and we stop scanning the moment we
/// have all the fields the memory estimator needs. The key prefix
/// varies by architecture (`llama.*`, `gemma3.*`, `qwen2.*`,
/// `phi3.*`, ...) so we match by suffix.
class GgufMetadataReader {
  const GgufMetadataReader();

  static const _magic = <int>[0x47, 0x47, 0x55, 0x46]; // "GGUF"

  /// Reads just enough of the GGUF header to populate
  /// [ModelArchitecture]. Returns `null` if the file is missing,
  /// unreadable, or doesn't look like GGUF v2/v3.
  Future<ModelArchitecture?> read(String filePath) async {
    if (kIsWeb) return null;
    final file = File(filePath);
    if (!await file.exists()) return null;

    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(24);
      if (header.length < 24) return null;
      final bd = ByteData.sublistView(header);
      for (var i = 0; i < 4; i++) {
        if (bd.getUint8(i) != _magic[i]) return null;
      }
      final version = bd.getUint32(4, Endian.little);
      if (version < 2 || version > 3) return null;
      final kvCount = bd.getUint64(16, Endian.little);

      var arch = const ModelArchitecture();
      // We want all 7 fields we know about; the cost of reading
      // extra uint32 KVs is negligible compared to the file open.
      var outstanding = 7;

      for (var i = 0; i < kvCount && outstanding > 0; i++) {
        final key = await _readString(raf);
        if (key == null) break;
        final valueTypeBytes = await raf.read(4);
        if (valueTypeBytes.length < 4) break;
        final valueType = ByteData.sublistView(valueTypeBytes).getUint32(
          0,
          Endian.little,
        );

        final result = await _skipOrReadValue(raf, valueType, (v) {
          final kind = _matchKey(key);
          if (kind == null) return;
          arch = _applyUint32(arch, kind, v);
          outstanding--;
        });
        if (!result) break;
      }
      return arch;
    } on FileSystemException {
      return null;
    } catch (_) {
      return null;
    } finally {
      await raf?.close();
    }
  }

  ModelArchitecture _applyUint32(
    ModelArchitecture arch,
    _KeyKind kind,
    int value,
  ) {
    switch (kind) {
      case _KeyKind.embeddingLength:
        return arch.copyWith(embeddingLength: value);
      case _KeyKind.blockCount:
        return arch.copyWith(blockCount: value);
      case _KeyKind.headCountKv:
        return arch.copyWith(headCountKv: value);
      case _KeyKind.keyLength:
        return arch.copyWith(keyLength: value);
      case _KeyKind.valueLength:
        return arch.copyWith(valueLength: value);
      case _KeyKind.vocabSize:
        return arch.copyWith(vocabSize: value);
      case _KeyKind.contextLength:
        return arch.copyWith(contextLength: value);
    }
  }

  _KeyKind? _matchKey(String key) {
    if (key.endsWith('.embedding_length')) return _KeyKind.embeddingLength;
    if (key.endsWith('.block_count')) return _KeyKind.blockCount;
    if (key.endsWith('.attention.head_count_kv')) {
      return _KeyKind.headCountKv;
    }
    if (key.endsWith('.attention.key_length')) return _KeyKind.keyLength;
    if (key.endsWith('.attention.value_length')) return _KeyKind.valueLength;
    if (key.endsWith('.vocab_size')) return _KeyKind.vocabSize;
    if (key.endsWith('.context_length')) return _KeyKind.contextLength;
    return null;
  }

  Future<String?> _readString(RandomAccessFile raf) async {
    final lenBytes = await raf.read(8);
    if (lenBytes.length < 8) return null;
    final len = ByteData.sublistView(lenBytes).getUint64(0, Endian.little);
    if (len > 1024 * 1024) return null; // sanity cap (1 MB key is absurd)
    final bytes = await raf.read(len);
    if (bytes.length < len) return null;
    return String.fromCharCodes(bytes);
  }

  Future<bool> _skipOrReadValue(
    RandomAccessFile raf,
    int valueType,
    void Function(int) onUint32,
  ) async {
    switch (valueType) {
      case 0: // UINT8
      case 1: // INT8
      case 7: // BOOL
        if ((await raf.read(1)).isEmpty) return false;
        return true;
      case 2: // UINT16
      case 3: // INT16
        if ((await raf.read(2)).length < 2) return false;
        return true;
      case 4: // UINT32
      case 5: // INT32
        {
          final b = await raf.read(4);
          if (b.length < 4) return false;
          if (valueType == 4) {
            onUint32(ByteData.sublistView(b).getUint32(0, Endian.little));
          }
          return true;
        }
      case 6: // FLOAT32
        if ((await raf.read(4)).length < 4) return false;
        return true;
      case 10: // UINT64
      case 11: // INT64
      case 12: // FLOAT64
        if ((await raf.read(8)).length < 8) return false;
        return true;
      case 8: // STRING
        final lenBytes = await raf.read(8);
        if (lenBytes.length < 8) return false;
        final len = ByteData.sublistView(lenBytes).getUint64(0, Endian.little);
        if (len > 64 * 1024 * 1024) return false;
        if ((await raf.read(len)).length < len) return false;
        return true;
      case 9: // ARRAY
        final lenBytes = await raf.read(8);
        if (lenBytes.length < 8) return false;
        final len = ByteData.sublistView(lenBytes).getUint64(0, Endian.little);
        final subTypeBytes = await raf.read(4);
        if (subTypeBytes.length < 4) return false;
        final subType = ByteData.sublistView(subTypeBytes).getUint32(
          0,
          Endian.little,
        );
        final elemSize = _scalarSize(subType);
        if (elemSize == null) return false; // variable-size element type
        if (len > 64 * 1024 * 1024) return false;
        final bytes = await raf.read(len * elemSize);
        if (bytes.length < len * elemSize) return false;
        return true;
      default:
        return false;
    }
  }

  int? _scalarSize(int type) {
    switch (type) {
      case 0:
      case 1:
      case 7:
        return 1;
      case 2:
      case 3:
        return 2;
      case 4:
      case 5:
      case 6:
        return 4;
      case 10:
      case 11:
      case 12:
        return 8;
      default:
        return null;
    }
  }
}

enum _KeyKind {
  embeddingLength,
  blockCount,
  headCountKv,
  keyLength,
  valueLength,
  vocabSize,
  contextLength,
}
