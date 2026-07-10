import 'package:hive_ce/hive.dart';

import 'note.dart';

/// Hive TypeAdapter for [Note].
///
/// Hand-written (no build_runner) to match the project's
/// `chat_session_adapter.dart` convention. Layout:
///
///   byte 0     : typeId (= 2)
///   byte 1     : version (= 1)
///   utf8       : id
///   utf8       : title
///   utf8       : content
///   int64 (BE) : createdAt µs
///   int64 (BE) : updatedAt µs
class NoteAdapter extends TypeAdapter<Note> {
  @override
  final int typeId = 2;

  @override
  Note read(BinaryReader reader) {
    final version = reader.readByte();
    if (version != 1) {
      throw HiveError('Unknown Note version: $version');
    }
    final id = reader.readString();
    final title = reader.readString();
    final content = reader.readString();
    final createdAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    final updatedAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    return Note(
      id: id,
      title: title,
      content: content,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  @override
  void write(BinaryWriter writer, Note obj) {
    writer
      ..writeByte(1)
      ..writeString(obj.id)
      ..writeString(obj.title)
      ..writeString(obj.content)
      ..writeInt(obj.createdAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.updatedAt.toUtc().microsecondsSinceEpoch);
  }
}
