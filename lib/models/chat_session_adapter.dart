import 'dart:convert';

import 'package:hive_ce/hive.dart';

import 'chat_session.dart';
import 'message.dart';
import 'todo_list.dart';

/// Hive TypeAdapter for [ChatSession].
///
/// We hand-write the adapter to keep the build pipeline simple (no
/// code-gen / build_runner step).
///
/// On-disk layout:
///
///   byte  0     : typeId (= 1)
///   byte  1     : version
///                   1 = legacy (no todo list)
///                   2 = adds `todoList` JSON (utf8, may be empty
///                       string for "no todo active")
///   varint      : id
///   utf8        : title
///   int64 (BE)  : createdAt µs
///   int64 (BE)  : updatedAt µs
///   int32 (BE)  : message count
///   × N         : ChatMessage JSON (utf8)
///   utf8        : (v2 only) TodoList JSON
///
/// V1 records round-trip as a [ChatSession] with
/// `todoList = TodoList.empty` so old installs upgrade cleanly.
class ChatSessionAdapter extends TypeAdapter<ChatSession> {
  @override
  final int typeId = 1;

  @override
  ChatSession read(BinaryReader reader) {
    final version = reader.readByte();
    if (version != 1 && version != 2) {
      throw HiveError('Unknown ChatSession version: $version');
    }
    final id = reader.readString();
    final title = reader.readString();
    final createdAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    final updatedAt = DateTime.fromMicrosecondsSinceEpoch(
      reader.readInt(),
      isUtc: true,
    ).toLocal();
    final count = reader.readInt();
    final messages = <ChatMessage>[];
    for (var i = 0; i < count; i++) {
      final json = jsonDecode(reader.readString()) as Map<String, dynamic>;
      messages.add(ChatMessage.fromJson(json));
    }
    TodoList todoList = TodoList.empty;
    if (version >= 2) {
      final rawTodo = reader.readString();
      if (rawTodo.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawTodo);
          if (decoded is Map) {
            todoList = TodoList.fromJson(decoded.cast<String, dynamic>());
          }
        } catch (_) {
          // A corrupt todo-list blob must NOT lose the user's
          // chat history — fall back to "no todo" and let the
          // session load cleanly. Same pattern as the legacy-
          // message migration in StorageService.
        }
      }
    }
    return ChatSession(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
      todoList: todoList,
    );
  }

  @override
  void write(BinaryWriter writer, ChatSession obj) {
    writer
      ..writeByte(2)
      ..writeString(obj.id)
      ..writeString(obj.title)
      ..writeInt(obj.createdAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.updatedAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.messages.length);
    for (final m in obj.messages) {
      writer.writeString(jsonEncode(m.toJson()));
    }
    // Persist the todo list as a single JSON blob. An empty list
    // serializes to `{}` which still round-trips cleanly; we
    // intentionally always emit the field on v2 (rather than
    // omitting it when empty) so the read path can rely on the
    // field being present after the version byte.
    final todoJson = jsonEncode(obj.todoList.toJson());
    writer.writeString(todoJson);
  }
}
