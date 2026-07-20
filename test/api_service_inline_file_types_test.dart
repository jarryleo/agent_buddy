import 'package:agent_buddy/models/file_attachment.dart';
import 'package:agent_buddy/models/file_type.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wire-format assertions for the supportedFileTypes gating in
/// [ApiService].
///
/// Rules pinned by these tests:
///   * **Text files are NEVER inlined** — the wire always emits a
///     path-only `<attached_file path="…" />` header for them,
///     regardless of the [inlineFileTypes] set. The `text` chip
///     in the settings UI is purely cosmetic (always-on, disabled)
///     and doesn't change the wire format.
///   * Non-text files (images / audio / video / documents) follow
///     the supported-set gate: if the category is in the set the
///     wire inlines the binary payload (file_data / image part /
///     document part); otherwise it falls back to the path-only
///     header.
///   * `null` [inlineFileTypes] preserves the cloud legacy
///     "inline non-text categories" behaviour. (Text still gets
///     path-only — see rule #1.)
void main() {
  group('ApiService.inlineFileTypes path-only fallback', () {
    const docFile = PreparedFileAttachment(
      name: 'report.pdf',
      path: r'C:\app\chat_files\1700_0__report.pdf',
      size: 1234,
      mimeType: 'application/pdf',
      base64Data: 'AAAA',
    );

    const textFile = PreparedFileAttachment(
      name: 'notes.txt',
      path: r'C:\app\chat_files\1700_1__notes.txt',
      size: 5,
      mimeType: 'text/plain',
      textContent: 'hello',
    );

    const imageDataUrl = 'data:image/png;base64,AAAA';

    group('text files are ALWAYS path-only', () {
      test(
        'OpenAI: text file gets the self-closing path header, no envelope body',
        () {
          final api = ApiService();
          final wire = api.buildOpenAIMessagesForTest(
            [
              ChatRequestMessage(
                role: MessageRole.user,
                content: 'Summarize',
                fileAttachments: [textFile],
              ),
            ],
            null,
            // `text` is in the set (default), but text files
            // are NEVER inlined regardless.
            {AgentFileType.text, AgentFileType.image, AgentFileType.document},
          );
          final userMessage =
              wire.singleWhere((m) => m['role'] == 'user') as Map;
          final content = userMessage['content'] as List;
          final textParts = content
              .whereType<Map>()
              .where((p) => p['type'] == 'text')
              .toList();
          // No inline text body — the previous envelope shape
          // (`<attached_file …>hello</attached_file>`) is gone.
          expect(
            textParts.any((p) => p['text'].toString().contains('hello')),
            isFalse,
          );
          // Path-only header is present and self-closing.
          expect(
            textParts.any(
              (p) =>
                  p['text'].toString().contains(
                    '<attached_file name="notes.txt"',
                  ) &&
                  p['text'].toString().contains(
                    r'path="C:\app\chat_files\1700_1__notes.txt"',
                  ) &&
                  p['text'].toString().endsWith('/>'),
            ),
            isTrue,
          );
        },
      );

      test('OpenAI: null inlineFileTypes still emits text as path-only', () {
        final api = ApiService();
        final wire = api.buildOpenAIMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Look',
              fileAttachments: [textFile],
            ),
          ],
          null,
          null,
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        expect(
          textParts.any((p) => p['text'].toString().contains('hello')),
          isFalse,
        );
        expect(
          textParts.any(
            (p) => p['text'].toString().contains(
              r'path="C:\app\chat_files\1700_1__notes.txt"',
            ),
          ),
          isTrue,
        );
      });

      test('Anthropic: text file gets the path-only header', () {
        final api = ApiService();
        final wire = api.buildAnthropicMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Summarize',
              fileAttachments: [textFile],
            ),
          ],
          {AgentFileType.text, AgentFileType.image, AgentFileType.document},
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        // No document / image part should appear for a text file.
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'document'),
          isEmpty,
        );
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'image'),
          isEmpty,
        );
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        expect(
          textParts.any((p) => p['text'].toString().contains('hello')),
          isFalse,
        );
        expect(
          textParts.any(
            (p) => p['text'].toString().contains(
              r'path="C:\app\chat_files\1700_1__notes.txt"',
            ),
          ),
          isTrue,
        );
      });
    });

    group('non-text files honor the inline gate', () {
      test('OpenAI: image disabled + document disabled → both path-only', () {
        final api = ApiService();
        final wire = api.buildOpenAIMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Look at this',
              imageDataUrls: [imageDataUrl],
              fileAttachments: [docFile],
            ),
          ],
          null,
          // Text files are always path-only regardless. Only
          // `text` is in the set; image and document are not.
          {AgentFileType.text},
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;

        expect(
          content.whereType<Map>().where((p) => p['type'] == 'image_url'),
          isEmpty,
        );
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'file'),
          isEmpty,
        );
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        expect(
          textParts.any(
            (p) =>
                p['text'].toString().contains(
                  '<attached_file name="report.pdf"',
                ) &&
                p['text'].toString().contains(
                  r'path="C:\app\chat_files\1700_0__report.pdf"',
                ),
          ),
          isTrue,
        );
      });

      test('OpenAI: document enabled → file_data part + path header', () {
        final api = ApiService();
        final wire = api.buildOpenAIMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Read this',
              fileAttachments: [docFile],
            ),
          ],
          null,
          {AgentFileType.text, AgentFileType.image, AgentFileType.document},
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'file'),
          hasLength(1),
        );
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        expect(
          textParts.any(
            (p) =>
                p['text'].toString().contains('<attached_file') &&
                p['text'].toString().contains(r'path='),
          ),
          isTrue,
        );
      });

      test('OpenAI: null set preserves "inline non-text" legacy behavior', () {
        final api = ApiService();
        final wire = api.buildOpenAIMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Look',
              imageDataUrls: [imageDataUrl],
              fileAttachments: [docFile, textFile],
            ),
          ],
          null,
          null,
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        // Image inline.
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'image_url'),
          hasLength(1),
        );
        // Document inline.
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'file'),
          hasLength(1),
        );
        // Text STILL path-only even with the legacy null set.
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        expect(
          textParts.any((p) => p['text'].toString().contains('hello')),
          isFalse,
        );
        expect(
          textParts.any(
            (p) => p['text'].toString().contains(
              r'path="C:\app\chat_files\1700_1__notes.txt"',
            ),
          ),
          isTrue,
        );
      });

      test('Anthropic: document disabled → document part suppressed', () {
        final api = ApiService();
        final wire = api.buildAnthropicMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Read this',
              fileAttachments: [docFile],
            ),
          ],
          {AgentFileType.text, AgentFileType.image},
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'document'),
          isEmpty,
        );
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        expect(
          textParts.any(
            (p) =>
                p['text'].toString().contains(
                  '<attached_file name="report.pdf"',
                ) &&
                p['text'].toString().contains(
                  r'path="C:\app\chat_files\1700_0__report.pdf"',
                ),
          ),
          isTrue,
        );
      });

      test('Anthropic: image disabled → image part suppressed', () {
        final api = ApiService();
        final wire = api.buildAnthropicMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Look',
              imageDataUrls: [imageDataUrl],
            ),
          ],
          {AgentFileType.text, AgentFileType.document},
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'image'),
          isEmpty,
        );
      });

      test('Anthropic: document enabled → document part + path header', () {
        final api = ApiService();
        final wire = api.buildAnthropicMessagesForTest(
          [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'Read',
              fileAttachments: [docFile],
            ),
          ],
          {AgentFileType.text, AgentFileType.document},
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        expect(
          content.whereType<Map>().where((p) => p['type'] == 'document'),
          hasLength(1),
        );
      });
    });
  });
}
