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

      // The orchestrator still yields the roundStart boundary
      // before consuming the runOneTurn stream's turnDone —
      // so the chat UI sees at least one event per round
      // attempt even when the underlying turn produced nothing.
      expect(events, hasLength(1));
      expect(events.single.kind, OrchestratorEventKind.roundStart);
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

      // We expect: roundStart (round 1), toolStart, toolDone
      // (in that order), then a roundStart for round 2 whose
      // runOneTurn yields no events. The round 2 roundStart
      // is the final yield; the orchestrator terminates when
      // round 2 emits a turnDone with no toolCalls.
      final kinds = events.map((e) => e.kind).toList();
      expect(kinds, [
        OrchestratorEventKind.roundStart,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.roundStart,
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

      // 3 rounds of (roundStart, toolStart, toolDone) + a final error.
      final kinds = events.map((e) => e.kind).toList();
      expect(kinds, [
        OrchestratorEventKind.roundStart,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.roundStart,
        OrchestratorEventKind.toolStart,
        OrchestratorEventKind.toolDone,
        OrchestratorEventKind.roundStart,
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
      // The round boundary is still yielded — it's the round
      // boundary itself that's the start of the round, not the
      // content.
      expect(events, hasLength(1));
      expect(events.single.kind, OrchestratorEventKind.roundStart);
    });

    test(
      'catches executor exceptions and reports the tool as failed',
      () async {
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
      },
    );

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

    test(
      'regression: live text from a final turn after 3 tool rounds',
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

        // 3 rounds of (roundStart, toolStart, toolDone) followed by
        // (roundStart, content, content) from the final turn.
        final kinds = events.map((e) => e.kind).toList();
        expect(kinds, [
          OrchestratorEventKind.roundStart,
          OrchestratorEventKind.toolStart,
          OrchestratorEventKind.toolDone,
          OrchestratorEventKind.roundStart,
          OrchestratorEventKind.toolStart,
          OrchestratorEventKind.toolDone,
          OrchestratorEventKind.roundStart,
          OrchestratorEventKind.toolStart,
          OrchestratorEventKind.toolDone,
          OrchestratorEventKind.roundStart,
          OrchestratorEventKind.content,
          OrchestratorEventKind.content,
        ]);
        expect(round, 4);
      },
    );

    group('roundStart boundary', () {
      test('emits roundStart(0) before the very first round', () async {
        final events = <OrchestratorEvent>[];
        final orch = ToolOrchestrator();

        Stream<OrchestratorEvent> runOneTurn(
          List<ChatRequestMessage> history,
        ) async* {
          yield const OrchestratorEvent.turnDone(
            TurnResult(emittedAnyContent: true),
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

        expect(events, hasLength(1));
        expect(events.single.kind, OrchestratorEventKind.roundStart);
        expect(events.single.roundIndex, 0);
      });

      test(
        'emits roundStart with monotonically increasing roundIndex',
        () async {
          final indices = <int>[];
          final orch = ToolOrchestrator(maxToolRounds: 4);

          Stream<OrchestratorEvent> runOneTurn(
            List<ChatRequestMessage> history,
          ) async* {
            // Every round emits one tool call so the loop keeps
            // running. The 4th round's runOneTurn won't run —
            // we hit maxToolRounds first.
            yield OrchestratorEvent.turnDone(
              TurnResult(
                toolCalls: [
                  ParsedToolCall(
                    id: 'call_x',
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
            if (ev.kind == OrchestratorEventKind.roundStart) {
              indices.add(ev.roundIndex ?? -1);
            }
          }

          expect(indices, [0, 1, 2, 3]);
        },
      );

      test('roundStart is emitted BEFORE the round\'s content / '
          'toolStart events', () async {
        // Regression guard: if the orchestrator ever started
        // emitting roundStart after the round's content (e.g.
        // accidentally moved below `await for`), ChatProvider
        // would mint the round-0 bubble AFTER content has
        // already been routed to it — i.e. content would land
        // on the wrong bubble. Pin down the ordering.
        final events = <OrchestratorEvent>[];
        final orch = ToolOrchestrator();

        Stream<OrchestratorEvent> runOneTurn(
          List<ChatRequestMessage> history,
        ) async* {
          yield OrchestratorEvent.content('hello ');
          yield OrchestratorEvent.content('world');
          yield OrchestratorEvent.turnDone(
            const TurnResult(emittedAnyContent: true),
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

        expect(events.map((e) => e.kind).toList(), [
          OrchestratorEventKind.roundStart,
          OrchestratorEventKind.content,
          OrchestratorEventKind.content,
        ]);
      });

      test('roundStart for a subsequent round arrives between the '
          'previous round\'s toolDone and the new round\'s '
          'content/toolStart', () async {
        // Mirrors the actual production event sequence: round
        // N's toolDone fires, then round N+1's roundStart
        // boundary, then round N+1's content / toolStart.
        // ChatProvider relies on this exact ordering to flip
        // `streaming: false` on round N's bubble before
        // minting round N+1's bubble — flipping it later
        // would leave the typing indicator on the now-closed
        // round N.
        final events = <OrchestratorEvent>[];
        final orch = ToolOrchestrator();

        var round = 0;
        Stream<OrchestratorEvent> runOneTurn(
          List<ChatRequestMessage> history,
        ) async* {
          round++;
          if (round == 1) {
            yield OrchestratorEvent.turnDone(
              TurnResult(
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
            yield OrchestratorEvent.content('answer');
            yield const OrchestratorEvent.turnDone(
              TurnResult(emittedAnyContent: true),
            );
          }
        }

        await for (final ev in orch.run(
          runOneTurn: runOneTurn,
          initialHistory: const <ChatRequestMessage>[],
          executor: (_) async => 'time',
          onTurnCommitted: (_) {},
        )) {
          events.add(ev);
        }

        expect(events.map((e) => e.kind).toList(), [
          OrchestratorEventKind.roundStart, // round 0
          OrchestratorEventKind.toolStart,
          OrchestratorEventKind.toolDone,
          OrchestratorEventKind.roundStart, // round 1
          OrchestratorEventKind.content,
        ]);
      });
    });
  });
}
