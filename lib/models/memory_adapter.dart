import 'package:hive_ce/hive.dart';

import 'memory.dart';

class MemoryAdapter extends TypeAdapter<Memory> {
  @override
  final int typeId = 4;

  @override
  Memory read(BinaryReader reader) {
    final version = reader.readByte();
    if (version != 1) {
      throw HiveError('Unknown Memory version: $version');
    }
    final id = reader.readString();
    final content = reader.readString();
    final source = reader.readString();
    final createdAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    return Memory(
      id: id,
      content: content,
      source: source,
      createdAt: createdAt,
    );
  }

  @override
  void write(BinaryWriter writer, Memory obj) {
    writer
      ..writeByte(1)
      ..writeString(obj.id)
      ..writeString(obj.content)
      ..writeString(obj.source)
      ..writeInt(obj.createdAt.toUtc().microsecondsSinceEpoch);
  }
}
