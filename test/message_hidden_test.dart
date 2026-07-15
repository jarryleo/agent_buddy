import 'package:agent_buddy/models/file_attachment.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatMessage.hidden', () {
    test('defaults to false on construction', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      expect(m.hidden, isFalse);
    });

    test('round-trips through JSON when true', () {
      final m = ChatMessage(
        id: 'm',
        role: MessageRole.user,
        content: '[系统计时触发] 喝水',
        hidden: true,
      );
      final round = ChatMessage.fromJson(m.toJson());
      expect(round.hidden, isTrue);
      expect(round.content, '[系统计时触发] 喝水');
    });

    test('round-trips through JSON when false (legacy v1 records)', () {
      // Older v1 records (pre-timer tool) don't have a `hidden`
      // key in the JSON at all. The reader should default to
      // `false` so the chat UI never accidentally hides a
      // historical user message.
      final legacy = <String, dynamic>{
        'id': 'legacy',
        'role': 'user',
        'content': 'Hello',
        'thinking': '',
        'createdAt': DateTime.now().toIso8601String(),
        'toolCalls': <dynamic>[],
        'imagePaths': <dynamic>[],
      };
      final m = ChatMessage.fromJson(legacy);
      expect(m.hidden, isFalse);
    });

    test('omits `hidden` from JSON when false (keeps records compact)', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      expect(m.toJson().containsKey('hidden'), isFalse);
    });

    test('copyWith preserves the flag when not specified', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user, hidden: true);
      final round = m.copyWith(content: 'updated');
      expect(round.hidden, isTrue);
      expect(round.content, 'updated');
    });

    test('file attachments round-trip and legacy messages default to none', () {
      final message = ChatMessage(
        id: 'file',
        role: MessageRole.user,
        fileAttachments: const [
          ChatFileAttachment(
            name: 'notes.txt',
            path: 'C:/files/notes.txt',
            size: 12,
            mimeType: 'text/plain',
          ),
        ],
      );
      final roundTrip = ChatMessage.fromJson(message.toJson());
      expect(roundTrip.fileAttachments, hasLength(1));
      expect(roundTrip.fileAttachments.single.name, 'notes.txt');
      expect(
        ChatMessage.fromJson({
          'id': 'legacy-file',
          'role': 'user',
        }).fileAttachments,
        isEmpty,
      );
    });

    test('copyWith can flip the flag', () {
      final m = ChatMessage(id: 'm', role: MessageRole.user);
      final hidden = m.copyWith(hidden: true);
      expect(hidden.hidden, isTrue);
      final unhidden = hidden.copyWith(hidden: false);
      expect(unhidden.hidden, isFalse);
    });
  });
}
