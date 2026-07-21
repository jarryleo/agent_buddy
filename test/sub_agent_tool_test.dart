import 'dart:convert';

import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/sub_agent_service.dart';
import 'package:agent_buddy/services/tool_orchestrator.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/sub_agent_tool.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubApiService extends ApiService {
  _StubApiService();
}

class _StubLocalLlmService extends LocalLlmService {
  _StubLocalLlmService();
}

class _ToolServiceWithSubAgent extends ToolService {
  _ToolServiceWithSubAgent(SubAgentService svc) : super(subAgent: svc);
}

/// Test transport that drives the sub-agent orchestrator with
/// scripted rounds. Returns a stream of `StreamEvent` matching
/// what the production code consumes.
Stream<StreamEvent> _scriptedTransport({
  required SubAgentConfig config,
  required List<String> systemPrompts,
  required List<ChatRequestMessage> messages,
  required List<Map<String, dynamic>> tools,
  required ToolOrchestrator orchestrator,
  required Future<String> Function(Map<String, dynamic> raw) onToolCall,
  List<List<OrchestratorEvent>>? rounds,
}) async* {
  // Default single-round script: yield a token of
  // content + a terminal turnDone so the sub-agent's
  // "empty report" check doesn't fire.
  final effectiveRounds =
      rounds ??
      [
        [
          OrchestratorEvent.content('r'),
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: true,
            ),
          ),
        ],
      ];
  var roundIndex = 0;
  yield* orchestrator
      .run(
        runOneTurn: (history) async* {
          if (roundIndex < effectiveRounds.length) {
            for (final event in effectiveRounds[roundIndex]) {
              yield event;
            }
          }
          roundIndex++;
        },
        initialHistory: const <ChatRequestMessage>[],
        executor: (_) async => 'unused',
        onTurnCommitted: (_) {},
      )
      .map(_toStreamEvent);
}

StreamEvent _toStreamEvent(OrchestratorEvent ev) {
  switch (ev.kind) {
    case OrchestratorEventKind.content:
      return StreamEvent(type: 'content', contentDelta: ev.contentDelta);
    case OrchestratorEventKind.reasoning:
      return StreamEvent(type: 'reasoning', thinkingDelta: ev.thinkingDelta);
    case OrchestratorEventKind.toolStart:
      return StreamEvent.toolStart(
        id: ev.toolId ?? '',
        name: ev.toolName ?? '',
        arguments: ev.toolArguments ?? '',
      );
    case OrchestratorEventKind.toolDone:
      return StreamEvent.toolDone(
        id: ev.toolId ?? '',
        name: ev.toolName ?? '',
        result: ev.toolResult ?? '',
        success: ev.toolSuccess ?? false,
        error: ev.toolError,
      );
    case OrchestratorEventKind.error:
      return StreamEvent(type: 'error', error: ev.error);
    case OrchestratorEventKind.usage:
      // Sub-agent doesn't surface per-request usage in tests;
      // forward any incoming event as a no-op so the switch
      // stays exhaustive.
      return const StreamEvent(type: 'usage');
    case OrchestratorEventKind.turnDone:
      return const StreamEvent(type: 'done', done: true);
    case OrchestratorEventKind.roundStart:
      // Round boundary — the sub-agent chat UI keeps a single
      // bubble for the report (see
      // [ChatProvider.formatSubAgentSnapshot]), so the round
      // marker is forwarded as a stream event for exhaustiveness
      // but the bridge doesn't act on it.
      return StreamEvent.roundStart(ev.roundIndex ?? 0);
  }
}

void main() {
  group('SubAgentTool list / get / cancel', () {
    late SubAgentService svc;
    late ToolService toolService;
    late SubAgentTool tool;

    setUp(() {
      svc = SubAgentService(
        apiService: _StubApiService(),
        localLlmService: _StubLocalLlmService(),
      );
      svc.setStreamFactory(_scriptedTransport);
      // Build a tool service that holds our sub-agent service.
      // We use the private field via a wrapper because
      // ToolService's `_subAgent` is private. The cleanest
      // approach is to wire through the constructor; since
      // `ToolService` exposes a public `subAgent` getter that
      // throws if not set, we need to set it via the
      // constructor (no setter). For the test we just set it
      // directly on a subclass that exposes the field.
      toolService = _ToolServiceWithSubAgent(svc);
      tool = SubAgentTool();
    });

    tearDown(() {
      svc.dispose();
    });

    test('list returns the most recent N tasks', () async {
      for (final t in ['a', 'b', 'c']) {
        await svc.run(
          config: const SubAgentConfig(useLocal: false),
          toolService: toolService,
          task: t,
          want: 'w',
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final env =
          jsonDecode(
                await tool.execute({'action': 'list', 'max': 2}, toolService),
              )
              as Map<String, dynamic>;
      expect(env['count'], 2);
      final tasks = (env['tasks'] as List).cast<Map<String, dynamic>>();
      // Newest-first: the last-inserted task comes first.
      expect(tasks.first['task'], 'c');
      expect(tasks.first, isNot(contains('tool_calls')));
      expect(tasks.first, isNot(contains('error')));
      expect(tasks.first, isNot(contains('context')));
    });

    test('get returns the task by id', () async {
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: toolService,
        task: 'find me',
        want: 'a result',
      );
      final id = svc.tasks.first.id;
      final env =
          jsonDecode(
                await tool.execute({'action': 'get', 'id': id}, toolService),
              )
              as Map<String, dynamic>;
      expect(env['found'], true);
      final t = env['task'] as Map<String, dynamic>;
      expect(t['task'], 'find me');
      expect(t['status'], 'completed');
      expect(t, isNot(contains('tool_calls')));
      expect(t, isNot(contains('error')));
    });

    test('get returns found:false for an unknown id', () async {
      final env =
          jsonDecode(
                await tool.execute({
                  'action': 'get',
                  'id': 'nope',
                }, toolService),
              )
              as Map<String, dynamic>;
      expect(env['found'], false);
      expect(env['id'], 'nope');
    });

    test('get rejects empty id', () async {
      expect(
        () => tool.execute({'action': 'get', 'id': ''}, toolService),
        throwsA(isA<ToolException>()),
      );
    });

    test('cancel flips a running task to cancelled', () async {
      // The transport cancels the orchestrator from inside
      // runOneTurn (so the flag survives the orchestrator's
      // `run` reset). The orchestrator bails out at the next
      // checkpoint with a "Generation stopped by user" error
      // event, which the sub-agent runner maps to cancelled.
      svc.setStreamFactory(({
        required SubAgentConfig config,
        required List<String> systemPrompts,
        required List<ChatRequestMessage> messages,
        required List<Map<String, dynamic>> tools,
        required ToolOrchestrator orchestrator,
        required Future<String> Function(Map<String, dynamic> raw) onToolCall,
      }) async* {
        yield* orchestrator
            .run(
              runOneTurn: (history) async* {
                // Cancel AFTER the run loop has started (the
                // orchestrator's `run` resets the flag at start).
                orchestrator.cancel();
                // Yield nothing — the orchestrator's `run` checks
                // `_cancelled` at the start of every round and
                // bails out.
              },
              initialHistory: const <ChatRequestMessage>[],
              executor: (_) async => 'unused',
              onTurnCommitted: (_) {},
            )
            .map(_toStreamEvent);
      });
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: toolService,
        task: 'long',
        want: 'w',
      );
      final id = svc.tasks.first.id;
      final t = svc.getById(id)!;
      expect(t.status, SubAgentStatus.cancelled);
    });

    test('cancel returns ok:true when the task is running', () async {
      // Set up a slow stream so the task is in `running` state
      // long enough for us to call cancel.
      svc.setStreamFactory(({
        required SubAgentConfig config,
        required List<String> systemPrompts,
        required List<ChatRequestMessage> messages,
        required List<Map<String, dynamic>> tools,
        required ToolOrchestrator orchestrator,
        required Future<String> Function(Map<String, dynamic> raw) onToolCall,
      }) async* {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        yield* orchestrator
            .run(
              runOneTurn: (history) async* {
                yield const OrchestratorEvent.turnDone(
                  TurnResult(
                    assistantTurn: null,
                    toolCalls: [],
                    emittedAnyContent: true,
                  ),
                );
              },
              initialHistory: const <ChatRequestMessage>[],
              executor: (_) async => 'unused',
              onTurnCommitted: (_) {},
            )
            .map(_toStreamEvent);
      });
      // Fire the run in the background.
      final raw = svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: toolService,
        task: 'X',
        want: 'Y',
      );
      // Grab the id out of the in-memory task list (the run
      // future hasn't resolved yet, but the task id is
      // assigned synchronously inside run()).
      final id = svc.tasks.first.id;
      final env =
          jsonDecode(
                await tool.execute({'action': 'cancel', 'id': id}, toolService),
              )
              as Map<String, dynamic>;
      expect(env['ok'], true);
      await raw; // let the background run finish
    });

    test('cancel returns ok:false for an unknown id', () async {
      final env =
          jsonDecode(
                await tool.execute({
                  'action': 'cancel',
                  'id': 'nope',
                }, toolService),
              )
              as Map<String, dynamic>;
      expect(env['ok'], false);
    });

    test('cancel rejects empty id', () async {
      expect(
        () => tool.execute({'action': 'cancel', 'id': ''}, toolService),
        throwsA(isA<ToolException>()),
      );
    });

    test('unknown action throws', () async {
      expect(
        () => tool.execute({'action': 'banana'}, toolService),
        throwsA(isA<ToolException>()),
      );
    });

    test(
      'delegate without chat-provider hook throws a helpful error',
      () async {
        // The tool layer doesn't know the per-turn transport
        // (that's the chat provider's job). Calling execute()
        // directly for the `delegate` action throws a clear
        // "handled by the chat provider" error so the model
        // doesn't think the call is wired but silent.
        expect(
          () => tool.execute({
            'action': 'delegate',
            'task': 'X',
            'want': 'Y',
          }, toolService),
          throwsA(
            isA<ToolException>().having(
              (e) => e.message,
              'message',
              contains('chat provider'),
            ),
          ),
        );
      },
    );

    test('list include_terminal=false excludes completed', () async {
      // Run a sub-agent that finishes so the list contains a
      // terminal entry.
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: toolService,
        task: 'done',
        want: 'w',
      );
      final env =
          jsonDecode(
                await tool.execute({
                  'action': 'list',
                  'include_terminal': false,
                }, toolService),
              )
              as Map<String, dynamic>;
      expect(env['count'], 0);
      final env2 =
          jsonDecode(
                await tool.execute({
                  'action': 'list',
                  'include_terminal': true,
                }, toolService),
              )
              as Map<String, dynamic>;
      expect(env2['count'], 1);
    });
  });
}
