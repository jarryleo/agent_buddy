import 'dart:convert';

import 'package:agent_buddy/models/file_attachment.dart';
import 'package:agent_buddy/models/file_type.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:llamadart/llamadart.dart';

/// Wire-format assertions for the `<attached_file … />` envelope
/// helpers and the user-message part layout. Pins:
///
///   * **Binary file headers** carry the local `path` so the model
///     can `file read` the same bytes the user picked. Skipped
///     when the file has no on-disk path (web fallback).
///   * **XML escaping** keeps attribute parsing safe when the
///     filename or path contains `&` or `"` (legal on Windows).
///   * **Text files are NEVER inlined** — the wire always emits a
///     self-closing path-only header, regardless of the
///     configured supported-types set.
///   * **Non-text files** follow the inline gate: the wire
///     emits a `file_data` / `document` / `image` part when the
///     category is in the supported set, otherwise just the
///     path header.
void main() {
  group('chat attachment path is forwarded to the model', () {
    test('binary file header carries the local path', () {
      final api = ApiService();
      const file = PreparedFileAttachment(
        name: 'report.pdf',
        path: r'C:\Users\me\chat_files\1700_0__report.pdf',
        size: 12345,
        mimeType: 'application/pdf',
        base64Data: 'AAAA',
      );

      final header = api.binaryFileHeaderForTest(file);

      expect(
        header,
        '<attached_file name="report.pdf" type="application/pdf" '
        r'path="C:\Users\me\chat_files\1700_0__report.pdf" />',
      );
    });

    test('omits the path attribute when the file has no on-disk path', () {
      // Web fallback: bytes live in `inlineBase64`, `path` is empty.
      // We must not emit a `path=""` attribute — the model would
      // try to open it and fail confusingly.
      final api = ApiService();
      const file = PreparedFileAttachment(
        name: 'notes.txt',
        path: '',
        size: 5,
        mimeType: 'text/plain',
        textContent: 'hello',
      );

      final header = api.binaryFileHeaderForTest(file);
      expect(header, contains('name="notes.txt"'));
      expect(header, isNot(contains('path=')));
    });

    test('XML-escapes quotes and ampersands in name/path', () {
      // Files on Windows can sit under `C:\foo & bar\` and the
      // original name might have quotes (rare but legal on some
      // filesystems). The envelope must not break attribute
      // parsing.
      final api = ApiService();
      const file = PreparedFileAttachment(
        name: 'a"b&c.txt',
        path: r'C:\foo & "bar"\chat_files\x.txt',
        size: 1,
        mimeType: 'text/plain',
        textContent: 'x',
      );

      final header = api.binaryFileHeaderForTest(file);
      expect(header, contains('name="a&quot;b&amp;c.txt"'));
      expect(
        header,
        contains(r'path="C:\foo &amp; &quot;bar&quot;\chat_files\x.txt"'),
      );
    });

    test('OpenAI wire payload: text file is path-only (no inline body)', () {
      // Text files always go path-only regardless of the
      // configured supported-types set. The model gets the
      // header so it can pull the file via the file tool, but
      // the decoded body is never inlined.
      final api = ApiService();
      const messages = [
        ChatRequestMessage(
          role: MessageRole.user,
          content: 'Summarize this',
          fileAttachments: [
            PreparedFileAttachment(
              name: 'notes.txt',
              path: r'C:\app\chat_files\1700_0__notes.txt',
              size: 5,
              mimeType: 'text/plain',
              textContent: 'hello',
            ),
          ],
        ),
      ];

      final wire = api.buildOpenAIMessagesForTest(messages, null);

      final userMessage = wire.singleWhere((m) => m['role'] == 'user');
      final content = userMessage['content'] as List;
      final textParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .toList();
      // Self-closing path header is present.
      expect(
        textParts.any(
          (p) =>
              p['text'].toString().contains(
                '<attached_file name="notes.txt"',
              ) &&
              p['text'].toString().endsWith('/>'),
        ),
        isTrue,
        reason: 'text files must emit the path-only self-closing header',
      );
      // Inline text body ('hello') is NOT present.
      expect(
        textParts.any((p) => p['text'].toString().contains('hello')),
        isFalse,
      );
      // And the user's actual message text is preserved.
      expect(
        textParts.any((p) => p['text'].toString() == 'Summarize this'),
        isTrue,
      );
    });

    test('OpenAI wire payload: text file path-only holds even when text is '
        'explicitly enabled', () {
      final api = ApiService();
      const messages = [
        ChatRequestMessage(
          role: MessageRole.user,
          content: 'Read this',
          fileAttachments: [
            PreparedFileAttachment(
              name: 'notes.txt',
              path: r'C:\app\chat_files\1700_1__notes.txt',
              size: 5,
              mimeType: 'text/plain',
              textContent: 'hello world',
            ),
          ],
        ),
      ];
      // Explicitly enable text — the wire must STILL emit
      // path-only. The settings UI marks `text` as always-on
      // (cosmetic) precisely because the wire behaviour doesn't
      // change with the toggle.
      final wire = api.buildOpenAIMessagesForTest(messages, null, {
        AgentFileType.text,
        AgentFileType.image,
        AgentFileType.document,
      });
      final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
      final content = userMessage['content'] as List;
      final textParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .toList();
      expect(
        textParts.any((p) => p['text'].toString().contains('hello world')),
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

    test(
      'OpenAI wire payload: binary file part is preceded by a path header',
      () async {
        Map<String, dynamic>? payload;
        final api = ApiService(
          client: MockClient((request) async {
            payload = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response('data: [DONE]\n\n', 200);
          }),
        );

        await api
            .streamChat(
              provider: ModelProvider(
                id: 'p',
                name: 'Test',
                protocol: ProviderProtocol.openai,
                baseUrl: 'https://example.com',
                apiKey: 'key',
                chatPath: ProviderProtocol.openai.defaultPath,
              ),
              model: 'any',
              messages: const [
                ChatRequestMessage(
                  role: MessageRole.user,
                  content: 'Look at this PDF',
                  fileAttachments: [
                    PreparedFileAttachment(
                      name: 'report.pdf',
                      path: r'C:\app\chat_files\1700_1__report.pdf',
                      size: 12345,
                      mimeType: 'application/pdf',
                      base64Data: 'AAAA',
                    ),
                  ],
                ),
              ],
            )
            .toList();

        expect(payload, isNotNull);
        final content =
            ((payload!['messages'] as List).single as Map)['content'] as List;
        final textParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .toList();
        final fileParts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'file')
            .toList();

        expect(textParts, hasLength(2));
        // The user content comes first; the file metadata header
        // (with the path) comes second.
        final headerPart = textParts.firstWhere(
          (p) => p['text'].toString().contains('<attached_file'),
        );
        expect(
          headerPart['text'],
          contains(
            r'<attached_file name="report.pdf" type="application/pdf" '
            r'path="C:\app\chat_files\1700_1__report.pdf" />',
          ),
        );
        expect(fileParts, hasLength(1));
        expect(fileParts.single['file'], {
          'filename': 'report.pdf',
          'file_data': 'data:application/pdf;base64,AAAA',
        });

        // The metadata header must come BEFORE the file part so
        // the model can read the path before processing the
        // binary blob.
        final headerIdx = content.indexOf(headerPart);
        final fileIdx = content.indexOf(fileParts.single);
        expect(
          headerIdx < fileIdx,
          isTrue,
          reason: 'binary file path header must precede the file_data part',
        );
      },
    );

    test('Anthropic wire payload: text file is path-only (no inline body)', () {
      final api = ApiService();
      const messages = [
        ChatRequestMessage(
          role: MessageRole.user,
          content: 'Read this',
          fileAttachments: [
            PreparedFileAttachment(
              name: 'notes.txt',
              path: r'C:\app\chat_files\1700_2__notes.txt',
              size: 5,
              mimeType: 'text/plain',
              textContent: 'hello world',
            ),
          ],
        ),
      ];

      final wire = api.buildAnthropicMessagesForTest(messages, {
        AgentFileType.text,
        AgentFileType.image,
        AgentFileType.document,
      });

      final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
      final content = userMessage['content'] as List;
      final textParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .toList();
      expect(
        textParts.any((p) => p['text'].toString().contains('hello world')),
        isFalse,
      );
      expect(
        textParts.any(
          (p) => p['text'].toString().contains(
            r'path="C:\app\chat_files\1700_2__notes.txt"',
          ),
        ),
        isTrue,
      );
    });

    test('Anthropic wire payload: binary document part has a path header', () {
      final api = ApiService();
      const messages = [
        ChatRequestMessage(
          role: MessageRole.user,
          content: 'Read this PDF',
          fileAttachments: [
            PreparedFileAttachment(
              name: 'report.pdf',
              path: r'C:\app\chat_files\1700_1__report.pdf',
              size: 12345,
              mimeType: 'application/pdf',
              base64Data: 'AAAA',
            ),
          ],
        ),
      ];

      final wire = api.buildAnthropicMessagesForTest(messages);

      final userMessage = wire.singleWhere((m) => m['role'] == 'user');
      final content = userMessage['content'] as List;
      final textParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .toList();
      final docParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'document')
          .toList();

      expect(textParts, hasLength(2));
      final headerPart = textParts.firstWhere(
        (p) => p['text'].toString().contains('<attached_file'),
      );
      expect(
        headerPart['text'],
        contains(
          r'<attached_file name="report.pdf" type="application/pdf" '
          r'path="C:\app\chat_files\1700_1__report.pdf" />',
        ),
      );
      expect(docParts, hasLength(1));
    });

    test('Anthropic image binary: still emits a path header', () {
      final api = ApiService();
      const messages = [
        ChatRequestMessage(
          role: MessageRole.user,
          content: 'Look',
          fileAttachments: [
            PreparedFileAttachment(
              name: 'photo.png',
              path: r'C:\app\chat_files\1700_2__photo.png',
              size: 1024,
              mimeType: 'image/png',
              base64Data: 'AAAA',
            ),
          ],
        ),
      ];

      final wire = api.buildAnthropicMessagesForTest(messages);
      final content =
          (wire.singleWhere((m) => m['role'] == 'user')['content'] as List);

      final textParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .toList();
      final imageParts = content
          .whereType<Map>()
          .where((p) => p['type'] == 'image')
          .toList();

      expect(textParts, hasLength(2));
      final headerPart = textParts.firstWhere(
        (p) => p['text'].toString().contains('<attached_file'),
      );
      expect(
        headerPart['text'],
        contains(r'path="C:\app\chat_files\1700_2__photo.png"'),
      );
      expect(imageParts, hasLength(1));
    });

    test('local LLM: text file is always path-only (no inline envelope)', () {
      final svc = LocalLlmService();
      const message = ChatRequestMessage(
        role: MessageRole.user,
        content: 'Read this',
        fileAttachments: [
          PreparedFileAttachment(
            name: 'notes.txt',
            path: r'C:\app\chat_files\1700_0__notes.txt',
            size: 5,
            mimeType: 'text/plain',
            textContent: 'hello',
          ),
        ],
      );

      final parts = svc.buildContentPartsForTest(message);
      final textParts = parts.whereType<LlamaTextContent>().toList();
      expect(textParts, hasLength(1));
      final text = textParts.single.text;
      // Local engine uses the `[Attached file: ...]` placeholder
      // for path-only references. The previous inline envelope
      // shape is gone — text bodies never enter the prompt.
      expect(
        text,
        contains(
          '[Attached file: notes.txt, type=text/plain, '
          r'path=C:\app\chat_files\1700_0__notes.txt]',
        ),
      );
      // The decoded body MUST NOT be inlined.
      expect(text, isNot(contains('hello')));
    });

    test('local LLM: text-file path-only is unaffected by inlineFileTypes', () {
      final svc = LocalLlmService();
      const message = ChatRequestMessage(
        role: MessageRole.user,
        content: 'Read this',
        fileAttachments: [
          PreparedFileAttachment(
            name: 'notes.txt',
            path: r'C:\app\chat_files\1700_3__notes.txt',
            size: 5,
            mimeType: 'text/plain',
            textContent: 'hello world',
          ),
        ],
      );

      // Even with `text` in the inline set, the local wire still
      // emits path-only for text files — the rule is uniform
      // across cloud and local.
      final parts = svc.buildContentPartsForTest(message, {
        AgentFileType.text,
        AgentFileType.image,
        AgentFileType.document,
      });
      final textParts = parts.whereType<LlamaTextContent>().toList();
      expect(textParts, hasLength(1));
      expect(textParts.single.text, isNot(contains('hello world')));
      expect(
        textParts.single.text,
        contains(
          '[Attached file: notes.txt, type=text/plain, '
          r'path=C:\app\chat_files\1700_3__notes.txt]',
        ),
      );
    });

    test('local LLM binary placeholder still carries the path', () {
      // The non-image, non-text branch was already emitting the
      // path before this change; this test pins the contract so
      // a future refactor doesn't silently drop it.
      final svc = LocalLlmService();
      const message = ChatRequestMessage(
        role: MessageRole.user,
        content: 'Look at this',
        fileAttachments: [
          PreparedFileAttachment(
            name: 'report.pdf',
            path: r'C:\app\chat_files\1700_1__report.pdf',
            size: 12345,
            mimeType: 'application/pdf',
            base64Data: 'AAAA',
          ),
        ],
      );

      final parts = svc.buildContentPartsForTest(message);
      final textParts = parts.whereType<LlamaTextContent>().toList();
      expect(textParts, hasLength(1));
      expect(
        textParts.single.text,
        contains(
          '[Attached file: report.pdf, type=application/pdf, '
          r'path=C:\app\chat_files\1700_1__report.pdf]',
        ),
      );
    });
  });
}
