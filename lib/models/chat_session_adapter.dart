import 'dart:convert';

import 'package:hive_ce/hive.dart';

import 'chat_session.dart';
import 'message.dart';

/// Hive TypeAdapter for [ChatSession].
///
/// We hand-write the adapter to keep the build pipeline simple (no
/// code-gen / build_runner step). Layout:
///
///   byte  0     : typeId (= 1)
///   byte  1     : version (= 1)
///   varint      : id
///   utf8        : title
///   int64 (BE)  : createdAt µs
///   int64 (BE)  : updatedAt µs
///   int32 (BE)  : message count
///   × N         : ChatMessage JSON (utf8)
class ChatSessionAdapter extends TypeAdapter<ChatSession> {
  @override
  final int typeId = 1;

  @override
  ChatSession read(BinaryReader reader) {
    final version = reader.readByte();
    if (version != 1) {
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
    return ChatSession(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
    );
  }

  @override
  void write(BinaryWriter writer, ChatSession obj) {
    writer
      ..writeByte(1)
      ..writeString(obj.id)
      ..writeString(obj.title)
      ..writeInt(obj.createdAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.updatedAt.toUtc().microsecondsSinceEpoch)
      ..writeInt(obj.messages.length);
    for (final m in obj.messages) {
      writer.writeString(jsonEncode(m.toJson()));
    }
  }
}
