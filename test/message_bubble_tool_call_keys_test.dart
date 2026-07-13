import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageBubble.disambiguateToolCallKeys', () {
    test('returns one key per call for unique ids', () {
      final calls = <ToolCall>[
        ToolCall(id: 'call_0', name: 'load_skill', arguments: '{}'),
        ToolCall(id: 'call_1', name: 'location', arguments: '{}'),
        ToolCall(id: 'call_2', name: 'fetch_web', arguments: '{}'),
      ];
      final keys = MessageBubble.disambiguateToolCallKeys(calls);
      expect(keys, hasLength(3));
      expect(keys.toSet().length, 3);
      expect(keys[0], 'tool_call_0');
      expect(keys[1], 'tool_call_1');
      expect(keys[2], 'tool_call_2');
    });

    test('appends #1, #2, … to disambiguate identical ids', () {
      // Regression: local models (llamadart + Hermes) can emit
      // the same id (e.g. "call_0") for every tool call in a
      // turn. Without this pass the Column in
      // `MessageBubble._buildToolCalls` throws "Duplicate keys
      // found" on the second `ValueKey('tool_call_0')`.
      final calls = <ToolCall>[
        ToolCall(id: 'call_0', name: 'load_skill', arguments: '{}'),
        ToolCall(id: 'call_0', name: 'location', arguments: '{}'),
        ToolCall(id: 'call_0', name: 'fetch_web', arguments: '{}'),
      ];
      final keys = MessageBubble.disambiguateToolCallKeys(calls);
      expect(keys, hasLength(3));
      expect(
        keys.toSet().length,
        3,
        reason: 'three identical ids must produce three distinct keys',
      );
      expect(
        keys[0],
        'tool_call_0',
        reason: 'first occurrence keeps the bare form for retry/lookup',
      );
      expect(keys[1], 'tool_call_0#1');
      expect(keys[2], 'tool_call_0#2');
    });

    test('handles empty ids (the very first duplicate-keys crash)', () {
      // Pre-Hermes regression: every tool call in a turn shared
      // the same empty id and the Column threw on the 2nd one.
      final calls = <ToolCall>[
        ToolCall(id: '', name: 'load_skill', arguments: '{}'),
        ToolCall(id: '', name: 'location', arguments: '{}'),
      ];
      final keys = MessageBubble.disambiguateToolCallKeys(calls);
      expect(keys.toSet().length, 2);
    });

    test('handles a mix of unique and colliding ids', () {
      final calls = <ToolCall>[
        ToolCall(id: 'unique_a', name: 't1', arguments: '{}'),
        ToolCall(id: 'call_0', name: 't2', arguments: '{}'),
        ToolCall(id: 'unique_b', name: 't3', arguments: '{}'),
        ToolCall(id: 'call_0', name: 't4', arguments: '{}'),
        ToolCall(id: 'call_0', name: 't5', arguments: '{}'),
      ];
      final keys = MessageBubble.disambiguateToolCallKeys(calls);
      expect(keys, hasLength(5));
      expect(keys.toSet().length, 5);
      expect(keys, [
        'tool_unique_a',
        'tool_call_0',
        'tool_unique_b',
        'tool_call_0#1',
        'tool_call_0#2',
      ]);
    });

    test('returns an empty list for an empty input', () {
      final keys = MessageBubble.disambiguateToolCallKeys(const []);
      expect(keys, isEmpty);
    });
  });
}
