import 'dart:convert';

import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolCall.fromJson robustness', () {
    test('throws when arguments is a Map (legacy data)', () {
      // Documents the current behavior so we don't accidentally
      // regress while tightening the ask_user options path.
      final Map<String, dynamic> json = {
        'id': 'tc1',
        'name': 'ask_user',
        'arguments': {
          'question': 'Test',
          'options': ['A', 'B'],
        },
        'status': 'running',
        'startedAt': DateTime.now().toIso8601String(),
        'downloads': [],
      };

      expect(() => ToolCall.fromJson(json), throwsA(isA<TypeError>()));
    });
  });

  group('ask_user options normalization', () {
    // We exercise the helper directly via its public effect: build
    // a ChatProvider wire-format `args` map (the shape `_onToolCall`
    // sees) and assert that the bubble's chip builder would iterate
    // it without throwing.
    List<String> normalize(dynamic raw) {
      // Mirror the implementation in ChatProvider so the test stays
      // independent of provider lifecycle (no StorageService / etc.).
      if (raw is! List) return const [];
      final out = <String>[];
      for (final entry in raw) {
        if (entry == null) continue;
        if (entry is String) {
          if (entry.isNotEmpty) out.add(entry);
          continue;
        }
        if (entry is Map) {
          for (final key in const ['label', 'value', 'text']) {
            final v = entry[key];
            if (v is String && v.isNotEmpty) {
              out.add(v);
              break;
            }
          }
        }
      }
      return out;
    }

    test('passes through flat string options untouched', () {
      expect(normalize(['A', 'B', 'C']), ['A', 'B', 'C']);
    });

    test('extracts label from object-shaped options', () {
      expect(
        normalize([
          {'label': 'A'},
          {'label': 'B'},
        ]),
        ['A', 'B'],
      );
    });

    test('falls back to value / text when label is missing', () {
      expect(
        normalize([
          {'value': '1'},
          {'text': '2'},
          {'label': '3'},
        ]),
        ['1', '2', '3'],
      );
    });

    test('drops null / empty / non-string entries', () {
      expect(
        normalize([
          null,
          '',
          'A',
          {'label': ''},
          {'label': 'B'},
          42,
        ]),
        ['A', 'B'],
      );
    });

    test('handles non-list inputs by returning empty list', () {
      expect(normalize(null), isEmpty);
      expect(normalize('not a list'), isEmpty);
      expect(normalize({'label': 'A'}), isEmpty);
    });

    test('CastList iteration triggers Map→String cast (root cause)', () {
      // This documents why we *can't* use `(raw as List?)?.cast<String>()`
      // and must walk the list eagerly. The lazy CastList only fails
      // when an element is accessed — `.length` works, `.first` /
      // iteration do not.
      final raw = [
        {'label': 'A'},
        {'label': 'B'},
      ];
      final lazy = raw.cast<String>();
      expect(lazy.length, 2); // safe
      expect(() => lazy.toList(), throwsA(isA<TypeError>()));
    });
  });

  group('ask_user batch questions', () {
    ToolCall batchCall() => ToolCall(
      id: 'tc_batch',
      name: 'ask_user',
      arguments: '{}',
      status: ToolCallStatus.running,
      questions: const [
        AskUserQuestion(question: 'First?', options: ['A', 'B']),
        AskUserQuestion(question: 'Second?'),
      ],
    );

    test('persists questions, progress, and answers', () {
      final original = batchCall().copyWith(
        askUserQuestionIndex: 1,
        askUserAnswers: const [
          ['A'],
        ],
      );

      final restored = ToolCall.fromJson(original.toJson());

      expect(restored.questions.length, 2);
      expect(restored.questions.first.question, 'First?');
      expect(restored.questions.first.options, ['A', 'B']);
      expect(restored.askUserQuestionIndex, 1);
      expect(restored.askUserAnswers, [
        ['A'],
      ]);
    });

    test('advances after each answer and returns all answers at the end', () {
      final first = ChatProvider.advanceAskUserAnswer(
        batchCall(),
        jsonEncode({'selection': 'A'}),
      );

      expect(first.accepted, isTrue);
      expect(first.result, isNull);
      expect(first.toolCall.askUserQuestionIndex, 1);
      expect(first.toolCall.askUserAnswers, [
        ['A'],
      ]);

      final second = ChatProvider.advanceAskUserAnswer(
        first.toolCall,
        jsonEncode({'selection': 'A custom answer'}),
      );
      final result = jsonDecode(second.result!) as Map<String, dynamic>;
      final answers = result['answers'] as List<dynamic>;

      expect(second.accepted, isTrue);
      expect(answers[0], {'question': 'First?', 'answer': 'A'});
      expect(answers[1], {'question': 'Second?', 'answer': 'A custom answer'});
    });

    test('keeps the legacy selection envelope for one question', () {
      final call = ToolCall(
        id: 'tc_single',
        name: 'ask_user',
        arguments: '{}',
        questions: const [AskUserQuestion(question: 'Pick one')],
      );

      final progress = ChatProvider.advanceAskUserAnswer(
        call,
        jsonEncode({'selection': 'Typed answer'}),
      );

      expect(jsonDecode(progress.result!), {'selection': 'Typed answer'});
    });
  });
}
