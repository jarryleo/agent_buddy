import 'package:agent_buddy/models/local_provider.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/tool_orchestrator.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalLlmService.resolveToolCallId', () {
    test('always synthesizes a non-empty id, even when raw is non-empty', () {
      // The raw id from llamadart is unreliable: it can be
      // null, empty, or — most importantly — collide across
      // sibling tool calls in the same turn (Hermes-style
      // models often emit `{"id": "call_0", ...}` for every
      // tool call). We always synthesize to guarantee
      // uniqueness for the UI bubble keys.
      final svc = LocalLlmService();
      expect(svc.resolveToolCallId(null), isNotEmpty);
      expect(svc.resolveToolCallId(''), isNotEmpty);
      expect(svc.resolveToolCallId('call_abc123'), isNotEmpty);
      expect(svc.resolveToolCallId('call_0'), isNotEmpty);
    });

    test('synthesizes a unique id when raw id is null', () {
      final svc = LocalLlmService();
      final id1 = svc.resolveToolCallId(null);
      final id2 = svc.resolveToolCallId(null);
      expect(id1, isNotEmpty);
      expect(id2, isNotEmpty);
      expect(id1, isNot(equals(id2)));
      expect(id1, startsWith('local-'));
      expect(id2, startsWith('local-'));
    });

    test('synthesizes a unique id when raw id is empty string', () {
      // Regression (round 1): a 404 on the 3rd tool call was
      // painting "failed 404" onto the 1st and 2nd because
      // all three shared the same empty id and the chat
      // provider's toolDone handler matched all of them.
      final svc = LocalLlmService();
      final ids = <String>{
        for (var i = 0; i < 3; i++) svc.resolveToolCallId(''),
      };
      expect(
        ids.length,
        3,
        reason: 'three empty ids must produce three distinct ids',
      );
    });

    test('synthesizes distinct ids even when raw ids collide', () {
      // Regression (round 2): Hermes-style models emit
      // `{"id": "call_0", ...}` for every tool call in a
      // turn. Without this guarantee, two sibling tool calls
      // in the same assistant message would both produce
      // `id: "call_0"`, and `ValueKey('tool_call_0')` would
      // collide in the MessageBubble Column, throwing
      // "Duplicate keys found".
      final svc = LocalLlmService();
      final ids = <String>{
        for (var i = 0; i < 3; i++) svc.resolveToolCallId('call_0'),
      };
      expect(
        ids.length,
        3,
        reason: 'three identical raw ids must produce three distinct ids',
      );
    });

    test('synthesized ids are stable across the lifetime of the service', () {
      final svc = LocalLlmService();
      // Counter must be monotonic within a service so callers
      // can rely on distinct ids.
      final first = svc.resolveToolCallId(null);
      final second = svc.resolveToolCallId(null);
      final third = svc.resolveToolCallId(null);
      expect(first, isNot(equals(second)));
      expect(second, isNot(equals(third)));
      expect(first, isNot(equals(third)));
    });

    test('a sequence simulating a 3-tool-call turn produces 3 unique ids', () {
      // Mirrors the user's reported scenario: load_skill,
      // location, fetch_web — all three arriving with the same
      // Hermes-style `call_0` id from the model.
      final svc = LocalLlmService();
      final ids = [
        svc.resolveToolCallId('call_0'),
        svc.resolveToolCallId('call_0'),
        svc.resolveToolCallId('call_0'),
      ];
      expect(ids.toSet().length, 3);
      for (final id in ids) {
        expect(
          id,
          isNot('call_0'),
          reason: 'synthesized id must not leak the colliding raw value',
        );
        expect(id, startsWith('local-'));
      }
    });
  });

  group('GemmaToolCallFallbackParser', () {
    test('hides a complete Chinese tool call and parses empty arguments', () {
      final parser = GemmaToolCallFallbackParser();

      final visible = parser.feed('<|tool_call>call:查询天气{}<tool_call|>');

      expect(visible, isEmpty);
      expect(parser.close(), isEmpty);
      expect(parser.calls, hasLength(1));
      expect(parser.calls.single.name, '查询天气');
      expect(parser.calls.single.arguments, isEmpty);
      expect(parser.calls.single.argumentsRaw, '{}');
    });

    test('handles markers and arguments split across stream chunks', () {
      final parser = GemmaToolCallFallbackParser();
      final visible = StringBuffer();

      visible.write(parser.feed('before <|tool_'));
      visible.write(parser.feed('call>call:location{"action":'));
      visible.write(parser.feed('"get"}<tool_'));
      visible.write(parser.feed('call|> after'));
      visible.write(parser.close());

      expect(visible.toString(), 'before  after');
      expect(parser.calls, hasLength(1));
      expect(parser.calls.single.name, 'location');
      expect(parser.calls.single.arguments, {'action': 'get'});
    });

    test('parses multiple calls and nested JSON in order', () {
      final parser = GemmaToolCallFallbackParser();

      final visible = parser.feed(
        '<|tool_call>call:location{}<tool_call|>'
        '<|tool_call>call:fetch_web{"meta":{"city":"北京"}}<tool_call|>',
      );

      expect(visible, isEmpty);
      expect(parser.close(), isEmpty);
      expect(parser.calls.map((call) => call.name), ['location', 'fetch_web']);
      expect(parser.calls.last.arguments, {
        'meta': {'city': '北京'},
      });
    });

    test('accepts Gemma pseudo quotes and unquoted argument keys', () {
      final parser = GemmaToolCallFallbackParser();

      parser.feed(
        '<|tool_call>call:fetch_web{url:<|"|>https://example.com<|"|>}<tool_call|>',
      );
      parser.close();

      expect(parser.calls.single.arguments, {'url': 'https://example.com'});
    });

    test('accepts a balanced call when the stop token removes the closer', () {
      final parser = GemmaToolCallFallbackParser();

      expect(parser.feed('<|tool_call>call:location{}'), isEmpty);
      expect(parser.close(), isEmpty);

      expect(parser.calls.single.name, 'location');
      expect(parser.calls.single.arguments, isEmpty);
    });

    test(
      'turns malformed arguments into a non-executable parse error call',
      () {
        final parser = GemmaToolCallFallbackParser();

        final visible = parser.feed(
          '<|tool_call>call:location{"action":}<tool_call|>',
        );

        expect(visible, isEmpty);
        expect(parser.close(), isEmpty);
        expect(
          parser.calls.single.name,
          GemmaToolCallFallbackParser.invalidToolName,
        );
        expect(parser.calls.single.arguments['attempted_name'], 'location');
      },
    );

    test('leaves non-call protocol-like text visible', () {
      final parser = GemmaToolCallFallbackParser();
      const text = '<|tool_call>not a call<tool_call|>';

      final visible = '${parser.feed(text)}${parser.close()}';

      expect(visible, text);
      expect(parser.calls, isEmpty);
    });
  });

  group('LocalLlmService.executeLocalToolCall', () {
    test(
      'does not execute unknown names and records corrective feedback',
      () async {
        var executed = false;
        final results = <String>[];
        const call = ParsedToolCall(
          id: 'call-1',
          name: '查询天气',
          argumentsRaw: '{}',
          arguments: {},
        );

        await expectLater(
          LocalLlmService.executeLocalToolCall(
            call: call,
            availableToolNames: {'location', 'fetch_web'},
            execute: () async {
              executed = true;
              return 'unexpected';
            },
            onResult: results.add,
          ),
          throwsA(
            isA<ToolException>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('unknown or unavailable tool: 查询天气'),
                contains('fetch_web, location'),
              ),
            ),
          ),
        );

        expect(executed, isFalse);
        expect(results, hasLength(1));
        expect(results.single, contains('Error: unknown or unavailable tool'));
      },
    );

    test('executes known names and records their result', () async {
      final results = <String>[];
      const call = ParsedToolCall(
        id: 'call-2',
        name: 'location',
        argumentsRaw: '{}',
        arguments: {},
      );

      final result = await LocalLlmService.executeLocalToolCall(
        call: call,
        availableToolNames: {'location'},
        execute: () async => '{"action":"get"}',
        onResult: results.add,
      );

      expect(result, '{"action":"get"}');
      expect(results, ['{"action":"get"}']);
    });

    test('records known tool failures before rethrowing', () async {
      final results = <String>[];
      const call = ParsedToolCall(
        id: 'call-3',
        name: 'location',
        argumentsRaw: '{}',
        arguments: {},
      );

      await expectLater(
        LocalLlmService.executeLocalToolCall(
          call: call,
          availableToolNames: {'location'},
          execute: () async => throw ToolException('permission denied'),
          onResult: results.add,
        ),
        throwsA(isA<ToolException>()),
      );

      expect(results, ['Error: permission denied']);
    });
  });

  group('LocalLlmService.resolveThinkingBudget', () {
    LocalProvider providerWith({int? thinkingBudgetTokens}) {
      return LocalProvider(
        id: 'p1',
        name: 'test',
        modelPath: '/tmp/model.gguf',
        thinkingBudgetTokens: thinkingBudgetTokens,
      );
    }

    test('returns null when thinking is disabled', () {
      // The reasoning sampler should not be active when the
      // user toggled thinking off in chat settings — even if
      // the provider has a budget configured.
      final budget = LocalLlmService.resolveThinkingBudget(
        provider: providerWith(thinkingBudgetTokens: 2048),
        enableThinking: false,
        supportsThinking: true,
      );
      expect(budget, isNull);
    });

    test('returns null when the engine cannot surface thinking', () {
      // Defensive: an engine that does not support reasoning
      // chunks (older backends, web) must never get a budget
      // even if everything else is set up correctly.
      final budget = LocalLlmService.resolveThinkingBudget(
        provider: providerWith(thinkingBudgetTokens: 2048),
        enableThinking: true,
        supportsThinking: false,
      );
      expect(budget, isNull);
    });

    test('returns null when the provider has no budget configured', () {
      // "No cap" is the user explicitly choosing the leftmost
      // tick on the slider. We must not invent a default behind
      // their back — the native backend would happily cap
      // reasoning at 0, which is equivalent to "always answer
      // immediately", so the default has to be the absence of
      // a budget, not a zero-token one.
      final budget = LocalLlmService.resolveThinkingBudget(
        provider: providerWith(thinkingBudgetTokens: null),
        enableThinking: true,
        supportsThinking: true,
      );
      expect(budget, isNull);
    });

    test('returns null when the provider budget is 0 (legacy sentinel)', () {
      // Older configs that survived the JSON round-trip with a
      // raw 0 must be treated as "no cap", same as null.
      final budget = LocalLlmService.resolveThinkingBudget(
        provider: providerWith(thinkingBudgetTokens: 0),
        enableThinking: true,
        supportsThinking: true,
      );
      expect(budget, isNull);
    });

    test('builds a ThinkingBudget when everything is in place', () {
      // The happy path: thinking is on, the provider has a
      // positive cap, the backend supports reasoning. The
      // returned budget must carry the same token count.
      final budget = LocalLlmService.resolveThinkingBudget(
        provider: providerWith(thinkingBudgetTokens: 2048),
        enableThinking: true,
        supportsThinking: true,
      );
      expect(budget, isNotNull);
      expect(budget!.maxTokens, 2048);
    });
  });
}
