import 'package:hive_ce/hive.dart';

import 'task.dart';

/// Hive TypeAdapter for [Task].
///
/// Hand-written (no build_runner) to match the project's
/// `chat_session_adapter.dart` convention. Layout:
///
///   byte 0     : typeId (= 3)
///   byte 1     : version (= 1)
///   utf8       : id
///   utf8       : title
///   utf8?      : notes (empty string == null)
///   int64 (BE) : due µs (0 == null)
///   bool       : completed
///   int64 (BE) : completedAt µs (0 == null)
///   int64 (BE) : createdAt µs
///   int64 (BE) : updatedAt µs
class TaskAdapter extends TypeAdapter<Task> {
  @override
  final int typeId = 3;

  @override
  Task read(BinaryReader reader) {
    final version = reader.readByte();
    if (version != 1) {
      throw HiveError('Unknown Task version: $version');
    }
    final id = reader.readString();
    final title = reader.readString();
    final notesRaw = reader.readString();
    final dueMicros = reader.readInt();
    final completed = reader.readBool();
    final completedAtMicros = reader.readInt();
    final createdAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    final updatedAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    return Task(
      id: id,
      title: title,
      notes: notesRaw.isEmpty ? null : notesRaw,
      due: dueMicros == 0
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              dueMicros,
              isUtc: true,
            ).toLocal(),
      completed: completed,
      completedAt: completedAtMicros == 0
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(
              completedAtMicros,
              isUtc: true,
            ).toLocal(),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  @override
  void write(BinaryWriter writer, Task obj) {
    writer
      ..writeByte(1)
      ..writeString(obj.id)
      ..writeString(obj.title)
      ..writeString(obj.notes ?? '')
      ..writeInt(obj.due?.toUtc().microsecondsSinceEpoch ?? 0)
      ..writeBool(obj.completed)
      ..writeInt(obj.completedAt?.toUtc().microsecondsSinceEpoch ?? 0)
      ..writeInt(obj.createdAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.updatedAt.toUtc().microsecondsSinceEpoch);
  }
}
