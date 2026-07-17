import 'dart:convert';

import 'package:agent_buddy/models/local_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalProvider.chatTemplate', () {
    LocalProvider make({String? chatTemplate}) => LocalProvider(
      id: 'p1',
      name: 'test',
      modelPath: '/tmp/model.gguf',
      chatTemplate: chatTemplate,
    );

    test('defaults to null (no override) when not supplied', () {
      // The legacy behavior must survive: a provider created via
      // the old constructor signature should not suddenly gain a
      // chat-template override because the field was added later.
      final p = LocalProvider(
        id: 'p1',
        name: 'test',
        modelPath: '/tmp/model.gguf',
      );
      expect(p.chatTemplate, isNull);
    });

    test('preserves an explicit non-null value', () {
      const tpl = '{% for m in messages %}{{ m.role }}{% endfor %}';
      expect(make(chatTemplate: tpl).chatTemplate, tpl);
    });

    test('preserves an explicit null (use the GGUF default)', () {
      expect(make(chatTemplate: null).chatTemplate, isNull);
    });

    test('toJson round-trips a non-empty template', () {
      const tpl = '{% if messages %}{{ messages[-1] }}{% endif %}';
      final p = make(chatTemplate: tpl);
      final restored = LocalProvider.fromJson(p.toJson());
      expect(restored.chatTemplate, tpl);
    });

    test('toJson round-trips a null template (no override)', () {
      final p = make(chatTemplate: null);
      final restored = LocalProvider.fromJson(p.toJson());
      expect(restored.chatTemplate, isNull);
    });

    test('fromJson treats missing field as null (older configs)', () {
      // Backwards compatibility: rows written before this field
      // existed must continue to deserialize with no template
      // override.
      final p = LocalProvider.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'test',
        'modelPath': '/tmp/model.gguf',
      });
      expect(p.chatTemplate, isNull);
    });

    test('fromJson coerces whitespace-only to null', () {
      // The on-disk form treats whitespace-only as "no override"
      // so a user clearing the textarea in the UI gets the same
      // runtime behavior as a freshly-created provider.
      for (final blank in ['', '   ', '\n\n', '\t  \n']) {
        final p = LocalProvider.fromJson(<String, dynamic>{
          'id': 'p1',
          'name': 'test',
          'modelPath': '/tmp/model.gguf',
          'chatTemplate': blank,
        });
        expect(
          p.chatTemplate,
          isNull,
          reason: 'whitespace-only input "$blank" must map to null',
        );
      }
    });

    test('fromJson preserves significant leading/trailing whitespace', () {
      // Internal whitespace inside Jinja is significant (e.g. the
      // newline after `{%- if ... %}`). We only trim to detect the
      // "all whitespace" sentinel — real templates pass through
      // verbatim.
      const tpl = '  {%- if messages %}\n  hi\n  {%- endif %}  ';
      final p = LocalProvider.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'test',
        'modelPath': '/tmp/model.gguf',
        'chatTemplate': tpl,
      });
      expect(p.chatTemplate, tpl);
    });

    test('fromJson coerces non-string to null', () {
      final p = LocalProvider.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'test',
        'modelPath': '/tmp/model.gguf',
        'chatTemplate': 42,
      });
      expect(p.chatTemplate, isNull);
    });

    test('fromRawJson round-trip preserves the template', () {
      const tpl = '{{ messages[-1].content }}';
      final p = make(chatTemplate: tpl);
      final restored = LocalProvider.fromRawJson(p.toRawJson());
      expect(restored.chatTemplate, tpl);
    });

    test('fromRawJson round-trip preserves null', () {
      final p = make(chatTemplate: null);
      final restored = LocalProvider.fromRawJson(p.toRawJson());
      expect(restored.chatTemplate, isNull);
    });

    test(
      'copyWith leaves the template untouched when the argument is omitted',
      () {
        // Common "edit one field" path: copyWith(name: 'foo') must
        // keep the chat-template override intact. Without the
        // sentinel pattern, the nullable field would always be
        // overwritten to null.
        final p = make(chatTemplate: '{{ messages }}');
        final p2 = p.copyWith(name: 'foo');
        expect(p2.chatTemplate, '{{ messages }}');
        expect(p2.name, 'foo');
      },
    );

    test('copyWith can clear the template by passing null', () {
      // Equally important: the user must be able to switch back
      // to the GGUF-bundled template by editing the form and
      // tapping the clear button. The sentinel pattern
      // distinguishes "argument omitted" from "argument = null".
      final p = make(chatTemplate: '{{ messages }}');
      final p2 = p.copyWith(chatTemplate: null);
      expect(p2.chatTemplate, isNull);
    });

    test('copyWith can set a new template', () {
      final p = make(chatTemplate: 'old');
      final p2 = p.copyWith(chatTemplate: 'new');
      expect(p2.chatTemplate, 'new');
    });

    test('toRawJson is parseable JSON containing the template field', () {
      // Lock in the wire format: the field is `chatTemplate`,
      // not `chat_template` or `template`. Renaming it would
      // silently break every existing provider on disk.
      const tpl = 'jinja-stuff';
      final raw = make(chatTemplate: tpl).toRawJson();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['chatTemplate'], tpl);
    });
  });
}
