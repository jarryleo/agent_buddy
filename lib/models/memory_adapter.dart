import 'package:hive_ce/hive.dart';

import 'memory.dart';

/// Hive TypeAdapter for [Memory].
///
/// Hand-written (no build_runner) to match the project's
/// `chat_session_adapter.dart` convention. Layout (v2):
///
///   byte  0     : typeId (= 4)
///   byte  1     : version (= 2)
///   utf8        : id
///   utf8        : content
///   utf8        : source
///   int64 (BE)  : createdAt µs
///   int32 (BE)  : tag count
///   × N         : tag utf8
///
/// v1 records (pre-tags) are still readable: the reader sees
/// `version=1`, reads the original 4 fields, and returns a
/// [Memory] with an empty `tags` list. New writes always use v2.
class MemoryAdapter extends TypeAdapter<Memory> {
  @override
  final int typeId = 4;

  @override
  Memory read(BinaryReader reader) {
    final version = reader.readByte();
    if (version != 1 && version != 2) {
      throw HiveError('Unknown Memory version: $version');
    }
    final id = reader.readString();
    final content = reader.readString();
    final source = reader.readString();
    final createdAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    final tags = <String>[];
    if (version >= 2) {
      final count = reader.readInt();
      for (var i = 0; i < count; i++) {
        tags.add(reader.readString());
      }
    }
    return Memory(
      id: id,
      content: content,
      source: source,
      createdAt: createdAt,
      tags: tags,
    );
  }

  @override
  void write(BinaryWriter writer, Memory obj) {
    writer
      ..writeByte(2)
      ..writeString(obj.id)
      ..writeString(obj.content)
      ..writeString(obj.source)
      ..writeInt(obj.createdAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.tags.length);
    for (final t in obj.tags) {
      writer.writeString(t);
    }
  }
}
