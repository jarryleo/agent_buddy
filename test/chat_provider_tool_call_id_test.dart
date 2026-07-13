import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatProvider.resolveToolCallBubbleId', () {
    test('returns the incoming id when it is non-empty and unique', () {
      final id = ChatProvider.resolveToolCallBubbleId(
        incomingId: 'call_abc123',
        existingToolCalls: const [],
      );
      expect(id, 'call_abc123');
    });

    test('synthesizes a uuid when the incoming id is empty', () {
      final id = ChatProvider.resolveToolCallBubbleId(
        incomingId: '',
        existingToolCalls: const [],
      );
      expect(id, isNotEmpty);
      expect(id, isNot(equals('')));
    });

    test('synthesizes a uuid when the incoming id is null-like (empty)', () {
      // Regression: the very first duplicate-keys crash — every
      // tool call in a turn shared the same empty id and the
      // MessageBubble Column threw on the second one.
      final ids = <String>{
        for (var i = 0; i < 3; i++)
          ChatProvider.resolveToolCallBubbleId(
            incomingId: '',
            existingToolCalls: const [],
          ),
      };
      expect(ids.length, 3);
    });

    test(
      'synthesizes a uuid when the incoming id collides with an existing bubble',
      () {
        // Regression: the second duplicate-keys crash — Hermes-style
        // models emit `{"id": "call_0", ...}` for every tool call
        // in a turn, so three siblings arrive as three `call_0`s.
        // Without this guard, the second one would crash the
        // Column in `MessageBubble._buildToolCalls` with
        // `ValueKey('tool_call_0')` repeated.
        final existing = <ToolCall>[
          ToolCall(id: 'call_0', name: 'load_skill', arguments: '{}'),
        ];
        final id = ChatProvider.resolveToolCallBubbleId(
          incomingId: 'call_0',
          existingToolCalls: existing,
        );
        expect(id, isNot('call_0'));
        expect(id, isNotEmpty);
      },
    );

    test('three siblings all with id "call_0" produce three distinct ids', () {
      // Mirrors the user's reported scenario: load_skill,
      // location, fetch_web — all three arriving with the same
      // Hermes-style `call_0` id from the local model.
      // The first one passes through (no collision yet). The
      // 2nd and 3rd must synthesize — otherwise the Column in
      // `MessageBubble` would throw on `ValueKey('tool_call_0')`
      // appearing twice.
      final List<ToolCall> existing = [];
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        final id = ChatProvider.resolveToolCallBubbleId(
          incomingId: 'call_0',
          existingToolCalls: existing,
        );
        ids.add(id);
        existing.add(ToolCall(id: id, name: 'tool_$i', arguments: '{}'));
      }
      expect(
        ids.toSet().length,
        3,
        reason: 'three "call_0" ids must produce three distinct UI ids',
      );
      // The 2nd and 3rd must have been synthesized (the raw
      // 'call_0' would have collided with the 1st bubble).
      expect(
        ids[1],
        isNot('call_0'),
        reason: '2nd sibling must synthesize (would collide with 1st)',
      );
      expect(
        ids[2],
        isNot('call_0'),
        reason: '3rd sibling must synthesize (would collide with 1st)',
      );
    });

    test('does not synthesize when the incoming id is unique vs. existing', () {
      // Sanity check: the happy path (server-generated unique
      // ids, or the local LLM path after `resolveToolCallId`)
      // must still pass through unchanged so the matching
      // `toolDone` event can find the bubble by id.
      final existing = <ToolCall>[
        ToolCall(id: 'call_0', name: 'load_skill', arguments: '{}'),
      ];
      final id = ChatProvider.resolveToolCallBubbleId(
        incomingId: 'call_1',
        existingToolCalls: existing,
      );
      expect(id, 'call_1');
    });
  });
}
