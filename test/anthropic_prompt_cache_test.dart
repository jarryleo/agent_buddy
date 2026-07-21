import 'dart:convert';

import 'package:agent_buddy/models/file_type.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Pin down the wire-format and SSE-parsing contract for
/// Anthropic-protocol prompt caching (MiniMax `cache_control`).
///
///   * Wire: `cache_control: {"type": "ephemeral"}` must be
///     attached to the LAST tool definition, the LAST system
///     block, and the LAST user-message block (regardless of
///     whether the user message is text-only or a multi-part
///     image/document content array). When the toggle is OFF the
///     wire must be byte-identical to the pre-caching behaviour
///     — no `cache_control` keys anywhere.
///   * SSE: the transport must surface `usage` on `message_start`
///     AND any updates on `message_delta`, and the final
///     `StreamEvent.usage` must carry the cumulative snapshot
///     (input + cache_read + cache_creation + output).
///   * Metrics: the per-turn metrics persisted on the chat
///     bubble must reflect the server-reported cache counts so
///     the UI can render a "⚡ cache hit N token" chip.
void main() {
  ModelProvider provider({
    ProviderProtocol protocol = ProviderProtocol.anthropic,
    bool promptCacheEnabled = true,
  }) {
    return ModelProvider(
      id: 'provider',
      name: 'Test',
      protocol: protocol,
      baseUrl: 'https://example.com',
      apiKey: 'key',
      chatPath: protocol.defaultPath,
      promptCacheEnabled: promptCacheEnabled,
    );
  }

  group('ModelProvider promptCacheEnabled persistence', () {
    test('round-trips through toJson/fromJson', () {
      final original = ModelProvider(
        id: 'p1',
        name: 'MiniMax',
        protocol: ProviderProtocol.anthropic,
        baseUrl: 'https://api.minimaxi.com/anthropic',
        apiKey: 'secret',
        chatPath: '/v1/messages',
        promptCacheEnabled: true,
      );
      final json = original.toJson();
      expect(json['promptCacheEnabled'], isTrue);

      final restored = ModelProvider.fromJson(json);
      expect(restored.promptCacheEnabled, isTrue);
      expect(restored.protocol, ProviderProtocol.anthropic);
    });

    test('defaults to false when key is absent (legacy rows)', () {
      // Older persisted rows don't have the key — the loader
      // must default to off so we don't accidentally turn
      // caching on for existing users on the upgrade.
      final restored = ModelProvider.fromJson({
        'id': 'p1',
        'name': 'Legacy',
        'protocol': 'anthropic',
        'baseUrl': 'https://example.com',
        'apiKey': 'k',
        'chatPath': '/v1/messages',
        'models': <String>[],
        'enabled': true,
        'createdAt': '2024-01-01T00:00:00.000Z',
      });
      expect(restored.promptCacheEnabled, isFalse);
    });

    test('omits the key when false so legacy rows round-trip identically', () {
      final original = ModelProvider(
        id: 'p1',
        name: 'NoCache',
        protocol: ProviderProtocol.openai,
        baseUrl: 'https://api.openai.com',
        apiKey: 'k',
        chatPath: '/v1/chat/completions',
        promptCacheEnabled: false,
      );
      final json = original.toJson();
      expect(json.containsKey('promptCacheEnabled'), isFalse);
    });
  });

  group('Anthropic cache_control wire format', () {
    test(
      'text-only user message gets a single text block with cache_control',
      () {
        // For a text-only user message, the wire must convert
        // the flat string into a single-block content array and
        // attach cache_control to that block — flat-string
        // content can't carry cache_control on its own.
        final api = ApiService();
        final wire = api.buildAnthropicMessagesForTest(
          const [ChatRequestMessage(role: MessageRole.user, content: 'Hello')],
          null,
          true,
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        expect(content, hasLength(1));
        final block = content.single as Map;
        expect(block['type'], 'text');
        expect(block['text'], 'Hello');
        expect(block['cache_control'], {'type': 'ephemeral'});
      },
    );

    test(
      'multi-part user message gets cache_control on the LAST block only',
      () {
        // For a user message with an image + a trailing text
        // part, only the LAST block carries the marker. Per the
        // MiniMax / Anthropic docs a single trailing marker is
        // enough — the server walks back up to 20 blocks to
        // find the longest matching prefix.
        final api = ApiService();
        final wire = api.buildAnthropicMessagesForTest(
          const [
            ChatRequestMessage(
              role: MessageRole.user,
              content: 'What is this?',
              imageDataUrls: ['data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='],
            ),
          ],
          {AgentFileType.image},
          true,
        );
        final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
        final content = userMessage['content'] as List;
        // text part first, then image part.
        expect(content.length, greaterThanOrEqualTo(2));
        final textBlock = content.first as Map;
        final imageBlock = content.last as Map;
        expect(textBlock['cache_control'], isNull);
        expect(imageBlock['cache_control'], {'type': 'ephemeral'});
      },
    );

    test('promptCacheEnabled=false keeps the flat-string wire format', () {
      // Backward compatibility: with caching OFF, text-only
      // user messages must keep emitting the flat-string
      // `content` shape (not a single-element array). OpenAI
      // protocol is unaffected either way, but the Anthropic
      // wire layer must not silently change.
      final api = ApiService();
      final wire = api.buildAnthropicMessagesForTest(
        const [ChatRequestMessage(role: MessageRole.user, content: 'Hello')],
        null,
        false,
      );
      final userMessage = wire.singleWhere((m) => m['role'] == 'user') as Map;
      // Flat string is preserved.
      expect(userMessage['content'], 'Hello');
    });

    test('cache_control is NOT added to the assistant turn', () {
      // The docs recommend NOT putting the marker on the
      // assistant turn itself (assistant turns change every
      // round, so caching them would mostly invalidate the
      // prefix anyway). Pin that behaviour so a future
      // refactor doesn't accidentally regress it.
      final api = ApiService();
      final wire = api.buildAnthropicMessagesForTest(
        const [
          ChatRequestMessage(role: MessageRole.user, content: 'Hello'),
          ChatRequestMessage(
            role: MessageRole.assistant,
            content: 'World',
            anthropicContentBlocks: [
              {'type': 'text', 'text': 'World'},
            ],
          ),
          ChatRequestMessage(role: MessageRole.user, content: 'Again'),
        ],
        null,
        true,
      );
      final assistantMessage =
          wire.singleWhere((m) => m['role'] == 'assistant') as Map;
      final blocks = assistantMessage['content'] as List;
      for (final b in blocks) {
        expect((b as Map).containsKey('cache_control'), isFalse);
      }
    });

    test('tools array attaches cache_control only to the LAST tool', () async {
      // The tool layer mirrors the same single-marker-on-the-
      // last-block strategy — the Anthropic / MiniMax server
      // walks back to find the longest matching prefix, so
      // marking every tool would just waste breakpoints.
      Map<String, dynamic>? payload;
      var calls = 0;
      final api = ApiService(
        client: MockClient((request) async {
          calls++;
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('data: [DONE]\n\n', 200);
        }),
      );

      await api
          .streamChat(
            provider: provider(),
            model: 'MiniMax-M2.7',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'Hi'),
            ],
            tools: const [
              {
                'type': 'function',
                'function': {
                  'name': 'first',
                  'description': 'first',
                  'parameters': {
                    'type': 'object',
                    'properties': <String, dynamic>{},
                  },
                },
              },
              {
                'type': 'function',
                'function': {
                  'name': 'second',
                  'description': 'second',
                  'parameters': {
                    'type': 'object',
                    'properties': <String, dynamic>{},
                  },
                },
              },
              {
                'type': 'function',
                'function': {
                  'name': 'third',
                  'description': 'third',
                  'parameters': {
                    'type': 'object',
                    'properties': <String, dynamic>{},
                  },
                },
              },
            ],
          )
          .toList();

      expect(calls, 1, reason: 'MockClient must be invoked exactly once');
      final tools = (payload!['tools'] as List).cast<Map>();
      expect(tools, hasLength(3));
      expect(tools[0]['cache_control'], isNull);
      expect(tools[1]['cache_control'], isNull);
      expect(tools[2]['cache_control'], {'type': 'ephemeral'});
    });

    test('system prompt gets cache_control on its LAST block', () async {
      // Multi-block system prompts (e.g. base + role + skills)
      // should attach the marker only to the last block. Same
      // single-marker strategy.
      Map<String, dynamic>? payload;
      final api = ApiService(
        client: MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('data: [DONE]\n\n', 200);
        }),
      );

      await api
          .streamChat(
            provider: provider(),
            model: 'MiniMax-M2.7',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'Hi'),
            ],
            systemPrompts: const [
              'You are a helpful assistant.',
              'Always answer in Mandarin.',
            ],
          )
          .toList();

      final system = payload!['system'] as List;
      expect(system, hasLength(2));
      expect((system[0] as Map)['cache_control'], isNull);
      expect((system[1] as Map)['cache_control'], {'type': 'ephemeral'});
    });

    test('system prompt uses flat-string format when caching is off', () async {
      // With caching OFF, the system field is the legacy flat
      // string (matches the pre-caching wire exactly).
      Map<String, dynamic>? payload;
      final api = ApiService(
        client: MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('data: [DONE]\n\n', 200);
        }),
      );

      await api
          .streamChat(
            provider: provider(promptCacheEnabled: false),
            model: 'MiniMax-M2.7',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'Hi'),
            ],
            systemPrompts: const ['You are a helpful assistant.'],
          )
          .toList();

      final system = payload!['system'];
      // Caching off → flat-string system. This keeps the
      // wire compatible with Anthropic-compatible endpoints
      // that don't yet support the array form.
      expect(system, 'You are a helpful assistant.');
    });

    test('OpenAI protocol ignores the prompt-cache flag', () async {
      // OpenAI-protocol transport must NOT add cache_control
      // markers even when the flag is on — OpenAI doesn't
      // honour the field and would 4xx.
      Map<String, dynamic>? payload;
      final api = ApiService(
        client: MockClient((request) async {
          payload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response('data: [DONE]\n\n', 200);
        }),
      );

      await api
          .streamChat(
            provider: provider(
              protocol: ProviderProtocol.openai,
              promptCacheEnabled: true,
            ),
            model: 'gpt-5',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'Hi'),
            ],
            tools: const [
              {
                'type': 'function',
                'function': {
                  'name': 'foo',
                  'description': 'foo',
                  'parameters': {
                    'type': 'object',
                    'properties': <String, dynamic>{},
                  },
                },
              },
            ],
            systemPrompts: const ['You are a helpful assistant.'],
          )
          .toList();

      expect(payload!.containsKey('cache_control'), isFalse);
      // OpenAI uses flat-string `system` (a separate `role`
      // message) — neither system nor tools should carry any
      // cache_control marker.
      final tools = (payload!['tools'] as List).cast<Map>();
      for (final t in tools) {
        expect(t.containsKey('cache_control'), isFalse);
      }
      final messages = (payload!['messages'] as List).cast<Map>();
      for (final m in messages) {
        expect(m.containsKey('cache_control'), isFalse);
      }
    });
  });

  group('Anthropic SSE usage parsing', () {
    String sseLine(Object payload) => 'data: ${jsonEncode(payload)}\n\n';

    test('message_start usage populates StreamEvent.usage', () async {
      // The very first SSE event carries the cumulative
      // input/cache counts. We expect the orchestrator to
      // forward a `usage` StreamEvent with the snapshot.
      final start = {
        'type': 'message_start',
        'message': {
          'usage': {
            'input_tokens': 100,
            'cache_creation_input_tokens': 188086,
            'cache_read_input_tokens': 0,
            'output_tokens': 0,
          },
        },
      };
      final stop = {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {
          'input_tokens': 100,
          'cache_creation_input_tokens': 188086,
          'cache_read_input_tokens': 0,
          'output_tokens': 393,
        },
      };
      final api = ApiService(
        client: MockClient((_) async {
          return http.Response(sseLine(start) + sseLine(stop), 200);
        }),
      );
      final events = await api
          .streamChat(
            provider: provider(),
            model: 'MiniMax-M2.7',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'Hi'),
            ],
          )
          .toList();

      final usage = events.where((e) => e.type == 'usage').toList();
      expect(usage, hasLength(1));
      expect(usage.single.usageInputTokens, 100);
      expect(usage.single.usageCacheCreationInputTokens, 188086);
      expect(usage.single.usageCacheReadInputTokens, 0);
      expect(usage.single.usageOutputTokens, 393);
    });

    test('message_delta usage updates cache counts on warm hits', () async {
      // The terminal message_delta carries the final output
      // token count and may re-broadcast input / cache counts
      // too (some implementations do). The wrapper prefers the
      // latest values.
      final start = {
        'type': 'message_start',
        'message': {
          'usage': {
            'input_tokens': 50,
            'cache_creation_input_tokens': 0,
            'cache_read_input_tokens': 188086,
            'output_tokens': 0,
          },
        },
      };
      final stop = {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {
          'input_tokens': 50,
          'cache_creation_input_tokens': 0,
          'cache_read_input_tokens': 188086,
          'output_tokens': 393,
        },
      };
      final api = ApiService(
        client: MockClient((_) async {
          return http.Response(sseLine(start) + sseLine(stop), 200);
        }),
      );
      final events = await api
          .streamChat(
            provider: provider(),
            model: 'MiniMax-M2.7',
            messages: const [
              ChatRequestMessage(role: MessageRole.user, content: 'Hi'),
            ],
          )
          .toList();

      final usage = events.where((e) => e.type == 'usage').toList();
      expect(usage, hasLength(1));
      // The warm-hit scenario: cache_read > 0, cache_creation = 0.
      expect(usage.single.usageCacheReadInputTokens, 188086);
      expect(usage.single.usageCacheCreationInputTokens, 0);
    });
  });

  group('MessageMetrics cache fields', () {
    test('cache fields default to 0 and persist through JSON', () {
      final m = MessageMetrics(
        turnStartedAt: DateTime(2026, 7, 21, 12),
        cacheReadInputTokens: 100,
        cacheCreationInputTokens: 50,
        cacheUncachedInputTokens: 25,
      );
      // hasServerUsage becomes true when ANY of the three
      // cache fields is non-zero.
      expect(m.hasServerUsage, isTrue);
      expect(m.totalServerInputTokens, 25 + 50 + 100);

      // JSON should serialize the cache fields when usage is
      // reported. Older code paths (no usage → all three at
      // 0) intentionally omit them so legacy records keep
      // round-tripping identically.
      final json = m.toJson();
      expect(json['cacheReadInputTokens'], 100);
      expect(json['cacheCreationInputTokens'], 50);
      expect(json['cacheUncachedInputTokens'], 25);

      final restored = MessageMetrics.fromJson(json);
      expect(restored.cacheReadInputTokens, 100);
      expect(restored.cacheCreationInputTokens, 50);
      expect(restored.cacheUncachedInputTokens, 25);
      expect(restored.hasServerUsage, isTrue);
    });

    test('zero cache fields are NOT serialized so legacy rows round-trip', () {
      // Pre-prompt-cache records: no cache fields, all 0.
      // toJson must omit them so deserialization lands on
      // the v1 default and fromJson doesn't add phantom
      // keys.
      final m = MessageMetrics(turnStartedAt: DateTime(2026, 7, 21));
      final json = m.toJson();
      expect(json.containsKey('cacheReadInputTokens'), isFalse);
      expect(json.containsKey('cacheCreationInputTokens'), isFalse);
      expect(json.containsKey('cacheUncachedInputTokens'), isFalse);

      // Legacy JSON without cache fields → restore with zero
      // cache counts and hasServerUsage == false.
      final restored = MessageMetrics.fromJson({
        'turnStartedAt': '2026-07-21T00:00:00.000',
        'outputTokens': 0,
        'inputTokens': 0,
      });
      expect(restored.cacheReadInputTokens, 0);
      expect(restored.hasServerUsage, isFalse);
    });
  });
}
