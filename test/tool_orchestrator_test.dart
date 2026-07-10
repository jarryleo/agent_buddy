import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/tool_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolOrchestrator', () {
    test('terminates after a turn that emits no tool calls', () async {
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator();

      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        // First and only turn: model says "done" with text but no tools.
        yield const OrchestratorEvent.turnDone(
          TurnResult(
            assistantTurn: null,
            toolCalls: [],
            emittedAnyContent: true,
          ),
        );
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (_) async => 'unused',
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      expect(events, isEmpty);
    });

    test('loops to execute tool calls and stops on follow-up text', () async {
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator(maxToolRounds: 5);

      var round = 0;
      final executorCalls = <ParsedToolCall>[];

      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        round++;
        if (round == 1) {
          // First turn: model asks for current time.
          yield OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [
                const ParsedToolCall(
                  id: 'call_1',
                  name: 'current_time',
                  argumentsRaw: '{}',
                  arguments: {},
                ),
              ],
              emittedAnyContent: true,
            ),
          );
        } else {
          // Second turn: model says "thanks" and stops.
          yield const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: true,
            ),
          );
        }
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (call) async {
          executorCalls.add(call);
          return '2026-07-10 12:00:00';
        },
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      // We expect: toolStart, toolDone (in that order, from round 1).
      // No events from round 2 because it's an empty-tool turn.
      final kinds = events.map((e) => e.kind).toList();
      expect(kinds, [
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
      ]);
      expect(executorCalls, hasLength(1));
      expect(executorCalls.single.id, 'call_1');
      expect(executorCalls.single.name, 'current_time');
      expect(round, 2);
    });

    test('respects maxToolRounds and surfaces an error', () async {
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator(maxToolRounds: 3);

      var round = 0;
      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        round++;
        yield OrchestratorEvent.turnDone(
          TurnResult(
            assistantTurn: null,
            toolCalls: [
              ParsedToolCall(
                id: 'call_$round',
                name: 'current_time',
                argumentsRaw: '{}',
                arguments: const <String, dynamic>{},
              ),
            ],
            emittedAnyContent: true,
          ),
        );
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (_) async => 'time',
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      // 3 rounds of (toolStart, toolDone) + a final error.
      final kinds = events.map((e) => e.kind).toList();
      expect(kinds, [
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.error,
      ]);
      expect(round, 3);
    });

    test('aborts on empty turn (no tools, no content)', () async {
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator(maxToolRounds: 10);

      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        yield const OrchestratorEvent.turnDone(
          TurnResult(emittedAnyContent: false),
        );
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (_) async => 'unused',
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      // An empty turn (no content, no tool calls) just terminates
      // the loop; the orchestrator doesn't synthesize a follow-up.
      expect(events, isEmpty);
    });

    test('catches executor exceptions and reports the tool as failed', () async {
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator();

      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        yield const OrchestratorEvent.turnDone(
          TurnResult(
            assistantTurn: null,
            toolCalls: [
              ParsedToolCall(
                id: 'call_1',
                name: 'fetch_web',
                argumentsRaw: '{}',
                arguments: {},
              ),
            ],
            emittedAnyContent: true,
          ),
        );
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (call) async {
          throw StateError('boom');
        },
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      // The orchestrator should have surfaced the failure and stopped
      // (the follow-up request is the orchestrator's next concern,
      // not this test's).
      final toolDone = events.firstWhere(
        (e) => e.kind == OrchestratorEventKind.toolDone,
      );
      expect(toolDone.toolSuccess, isFalse);
      expect(toolDone.toolResult, contains('Error:'));
      expect(toolDone.toolError, contains('boom'));
    });

    test('forwards live content deltas to the outer stream', () async {
      // Regression: a multi-round flow where the FINAL turn emits
      // text content must reach the caller, otherwise the chat UI
      // shows an empty bubble. This was the bug the user reported:
      // "after 3 tool calls, no text reply".
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator(maxToolRounds: 5);

      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        if (history.isEmpty) {
          // First round: model asks for time.
          yield OrchestratorEvent.content('thinking...');
          yield OrchestratorEvent.turnDone(
            const TurnResult(
              toolCalls: [
                ParsedToolCall(
                  id: 'call_1',
                  name: 'current_time',
                  argumentsRaw: '{}',
                  arguments: {},
                ),
              ],
              emittedAnyContent: true,
            ),
          );
        } else {
          // Second round: model streams the final answer.
          yield OrchestratorEvent.content('Tomorrow in Guangzhou: ');
          yield OrchestratorEvent.content('sunny, 28°C.');
          yield const OrchestratorEvent.turnDone(
            TurnResult(emittedAnyContent: true),
          );
        }
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (_) async => '2026-07-10 12:00:00',
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      // Both live content deltas must make it out, alongside the
      // toolStart/toolDone pair from round 1.
      final contentDeltas = events
          .where((e) => e.kind == OrchestratorEventKind.content)
          .map((e) => e.contentDelta)
          .toList();
      expect(contentDeltas, [
        'thinking...',
        'Tomorrow in Guangzhou: ',
        'sunny, 28°C.',
      ]);
    });

    test('regression: live text from a final turn after 3 tool rounds',
        () async {
      // Mirrors the exact user scenario: 1 time tool + 2 web tools
      // followed by a final text-only answer turn. The final turn's
      // text must be forwarded.
      final events = <OrchestratorEvent>[];
      final orch = ToolOrchestrator(maxToolRounds: 6);

      var round = 0;
      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        round++;
        if (round <= 3) {
          // Rounds 1-3: each emits exactly one tool call.
          yield OrchestratorEvent.turnDone(
            TurnResult(
              toolCalls: [
                ParsedToolCall(
                  id: 'call_$round',
                  name: 'fetch_web',
                  argumentsRaw: '{}',
                  arguments: const <String, dynamic>{},
                ),
              ],
              emittedAnyContent: true,
            ),
          );
        } else {
          // Round 4: final answer with text.
          yield OrchestratorEvent.content('广州明天');
          yield OrchestratorEvent.content('天气晴');
          yield const OrchestratorEvent.turnDone(
            TurnResult(emittedAnyContent: true),
          );
        }
      }

      await for (final ev in orch.run(
        runOneTurn: runOneTurn,
        initialHistory: const <ChatRequestMessage>[],
        executor: (_) async => 'ok',
        onTurnCommitted: (_) {},
      )) {
        events.add(ev);
      }

      // 3 rounds of (toolStart, toolDone) followed by 2 content deltas
      // from the final turn.
      final kinds = events.map((e) => e.kind).toList();
      expect(kinds, [
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.content,
        OrchestratorEventKind.content,
      ]);
      expect(round, 4);
    });
  });
}
