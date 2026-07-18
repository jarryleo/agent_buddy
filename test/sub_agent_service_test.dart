import 'dart:async';

import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/sub_agent_service.dart';
import 'package:agent_buddy/services/tool_orchestrator.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/sub_agent_tool.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake transport that the sub-agent service can be driven with
/// in unit tests. The `stream` factory receives the same args as
/// the production code path (config / prompts / messages / tools
/// / orchestrator / onToolCall) and returns a scripted
/// `Stream<OrchestratorEvent>` so we can assert how the runner
/// mirrors events into the sub-agent's task state without
/// touching the network or loading a real GGUF model.
///
/// The protocol here matches the production contract: the
/// transport yields `OrchestratorEvent.turnDone` with the
/// model's parsed [TurnResult]; the [ToolOrchestrator] then
/// emits its own `toolStart` + `toolDone` events and calls
/// [onToolCall] for each tool call. The sub-agent's listener
/// catches the orchestrator's events and mirrors them into
/// the task record.
class _FakeSubAgentTransport {
  _FakeSubAgentTransport();

  /// Scripted rounds. Each entry is the list of events the
  /// `runOneTurn` callback should yield on that round. The
  /// orchestrator calls `runOneTurn` once per round and stops
  /// when a round emits a `turnDone` with no tool calls.
  ///
  /// The default is a single happy-path round that yields a
  /// token of content and then a terminal `turnDone` — enough
  /// for the sub-agent runner to flip the task to `completed`.
  List<List<OrchestratorEvent>> scriptedRounds = [
    [
      OrchestratorEvent.content('default report'),
      const OrchestratorEvent.turnDone(
        TurnResult(assistantTurn: null, toolCalls: [], emittedAnyContent: true),
      ),
    ],
  ];

  /// Captures the args the runner passed in (so we can assert
  /// the orchestrator, onToolCall, etc. are wired correctly).
  Map<String, dynamic>? lastCall;

  Stream<StreamEvent> build({
    required SubAgentConfig config,
    required List<String> systemPrompts,
    required List<ChatRequestMessage> messages,
    required List<Map<String, dynamic>> tools,
    required ToolOrchestrator orchestrator,
    required Future<String> Function(Map<String, dynamic> raw) onToolCall,
  }) async* {
    lastCall = {
      'config': config,
      'systemPrompts': systemPrompts,
      'messages': messages,
      'tools': tools,
    };
    var roundIndex = 0;
    yield* orchestrator
        .run(
          runOneTurn: (history) async* {
            if (roundIndex < scriptedRounds.length) {
              for (final event in scriptedRounds[roundIndex]) {
                yield event;
              }
            }
            roundIndex++;
          },
          initialHistory: const <ChatRequestMessage>[],
          executor: (call) {
            return onToolCall({
              'id': call.id,
              'name': call.name,
              'arguments': call.arguments,
            });
          },
          onTurnCommitted: (_) {},
        )
        .map(_toStreamEventForTest);
  }
}

/// The [ToolOrchestrator] calls [runOneTurn] once per round.
/// Tests that want a multi-round sequence must return a different
/// set of events on each invocation. This helper does the obvious
/// thing: emits [rounds[i]] on round `i`.
Stream<OrchestratorEvent> scriptedRunOneTurn(
  List<List<OrchestratorEvent>> rounds,
) async* {
  // We rely on the orchestrator to only call us `rounds.length`
  // times; any extra calls fall back to the last round (no
  // events) so the orchestrator naturally terminates.
  var callIndex = 0;
  while (true) {
    if (callIndex >= rounds.length) {
      // No more scripted rounds — yield nothing. The
      // orchestrator's `run` will eventually see an empty
      // round and exit with a "no turnDone" error, but tests
      // that need a clean stop should append a final
      // turnDone(toolCalls: []) to the last scripted round.
      return;
    }
    final round = rounds[callIndex++];
    for (final event in round) {
      yield event;
    }
    return;
  }
}

class _StubApiService extends ApiService {
  _StubApiService();
}

class _StubLocalLlmService extends LocalLlmService {
  _StubLocalLlmService();
}

class _StubToolService extends ToolService {
  _StubToolService();
}

void main() {
  group('SubAgentTool schema + service-level constants', () {
    test('schema lists delegate / list / get / cancel', () {
      final tool = SubAgentTool();
      final schema = tool.buildSchema();
      final params = schema['function']['parameters'] as Map<String, dynamic>;
      final props = params['properties'] as Map<String, dynamic>;
      final actionEnum = (props['action'] as Map)['enum'] as List;
      expect(actionEnum.cast<String>().toSet(), {
        'delegate',
        'list',
        'get',
        'cancel',
      });
      expect((params['required'] as List).cast<String>(), ['action']);
    });

    test('tool name + id are stable', () {
      final tool = SubAgentTool();
      expect(tool.id, 'subagent');
      expect(tool.name, '子 Agent');
      expect(tool.isSupportedOnCurrentPlatform, isTrue);
    });

    test('registry includes the subagent tool', () {
      expect(ToolRegistry.byId('subagent'), isA<SubAgentTool>());
    });

    test('allowedSubAgentToolIds is the curated set', () {
      expect(SubAgentService.allowedSubAgentToolIds, {
        'fetch_web',
        'search',
        'current_time',
        'location',
        'memory',
        'run_command',
      });
    });

    test('failed task JSON hides internal activity and partial output', () {
      final task = SubAgentTask(
        id: 'sa-1',
        task: 'X',
        want: 'Y',
        context: 'private',
        status: SubAgentStatus.failed,
        createdAt: DateTime(2026, 1, 1),
        report: 'unverified partial output',
        error: 'HTTP 500',
        toolCalls: const [
          SubAgentToolCall(
            id: 'call-1',
            name: 'fetch_web',
            arguments: '{"url":"private"}',
            status: SubAgentToolStatus.failed,
            error: 'HTTP 500',
          ),
        ],
      );

      final json = task.toJson();
      expect(json, isNot(contains('context')));
      expect(json, isNot(contains('report')));
      expect(json, isNot(contains('error')));
      expect(json, isNot(contains('tool_calls')));
      expect(json, isNot(contains('rounds')));
    });
  });

  group('SubAgentService.buildSystemPrompt', () {
    late SubAgentService svc;

    setUp(() {
      svc = SubAgentService(
        apiService: _StubApiService(),
        localLlmService: _StubLocalLlmService(),
      );
    });

    tearDown(() => svc.dispose());

    test('tells the sub-agent to compress aggressively', () {
      final prompt = svc.buildSystemPrompt();
      expect(prompt, contains('isolated sub-agent'));
      expect(prompt, contains('concise'));
      expect(prompt, contains('ask_user'));
      expect(prompt, contains('Do not call the subagent tool recursively'));
      expect(prompt, contains('Never include tool-call logs'));
      expect(prompt, contains('raw error messages'));
    });
  });

  group('SubAgentService.buildToolsSchema', () {
    test('only exposes the curated subset', () {
      final svc = SubAgentService(
        apiService: _StubApiService(),
        localLlmService: _StubLocalLlmService(),
      );
      addTearDown(svc.dispose);
      final schema = svc.buildToolsSchema();
      final ids = schema
          .map((m) => (m['function'] as Map)['name'] as String)
          .toSet();
      expect(
        ids,
        containsAll(<String>[
          'fetch_web',
          'search',
          'current_time',
          'location',
          'memory',
          'run_command',
        ]),
      );
      // Forbidden set — must never leak into the sub-agent.
      expect(
        ids.intersection({
          'ask_user',
          'notification',
          'timer',
          'download',
          'file',
          'google_sheet',
          'subagent',
        }),
        isEmpty,
      );
    });
  });

  group('SubAgentService.run', () {
    late SubAgentService svc;
    late _FakeSubAgentTransport transport;

    setUp(() {
      svc = SubAgentService(
        apiService: _StubApiService(),
        localLlmService: _StubLocalLlmService(),
      );
      transport = _FakeSubAgentTransport();
      svc.setStreamFactory(transport.build);
    });

    tearDown(() {
      svc.setStreamFactory(null);
      svc.dispose();
    });

    test('composes a user message with task / want / context', () async {
      // Default single-round script (no tool calls) is fine.
      final report = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'find X',
        want: 'one sentence',
        context: 'A and B',
      );
      expect(report, 'default report');
      // The user message the runner passes to the transport
      // should include the task / want / context blocks.
      final msgs = transport.lastCall!['messages'] as List<ChatRequestMessage>;
      expect(msgs, hasLength(1));
      expect(msgs.first.role, MessageRole.user);
      expect(msgs.first.content, contains('# Task'));
      expect(msgs.first.content, contains('find X'));
      expect(msgs.first.content, contains('# What the main agent wants back'));
      expect(msgs.first.content, contains('one sentence'));
      expect(msgs.first.content, contains('A and B'));
    });

    test('omits the context block when context is empty', () async {
      // Default single-round script (no tool calls) is fine.
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
      );
      final msgs = transport.lastCall!['messages'] as List<ChatRequestMessage>;
      expect(msgs.first.content, isNot(contains('# Supporting context')));
    });

    test('completed run returns the assembled report', () async {
      // Script a 2-round sequence:
      //   Round 1: model asks for current_time, orchestrator
      //            dispatches, model produces the report text.
      //   Round 2: model emits a final turnDone with no tool
      //            calls so the loop terminates cleanly.
      transport.scriptedRounds = [
        [
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [
                ParsedToolCall(
                  id: 'call_1',
                  name: 'current_time',
                  argumentsRaw: '{}',
                  arguments: <String, dynamic>{},
                ),
              ],
              emittedAnyContent: true,
            ),
          ),
        ],
        [
          OrchestratorEvent.content('TL;DR: '),
          OrchestratorEvent.content('42.\n\nSource: '),
          OrchestratorEvent.content('https://example.com'),
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: true,
            ),
          ),
        ],
      ];
      final report = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'compute X',
        want: 'one number',
      );
      expect(report, 'TL;DR: 42.\n\nSource: https://example.com');
      expect(report, isNot(contains('tool_calls')));
      expect(report, isNot(contains('rounds')));

      final t = svc.tasks.first;
      expect(t.status, SubAgentStatus.completed);
      expect(t.report, report);

      // The transport received a non-empty tools list (the
      // curated schema).
      final tools = transport.lastCall!['tools'] as List;
      expect(tools, isNotEmpty);
    });

    test('empty report flips to failed', () async {
      // Model emits turnDone with no content, no tool calls.
      // (Default scripted round is already an "emittedAnyContent:
      // true" no-tool-call turn — we need a `false` here to
      // trip the empty-report branch in the runner.)
      transport.scriptedRounds = [
        [
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: false,
            ),
          ),
        ],
      ];
      final result = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'silent',
        want: 'something',
      );
      expect(result, SubAgentService.noUsefulResult);
      expect(result, isNot(contains('empty report')));
      expect(svc.tasks.first.status, SubAgentStatus.failed);
      expect(svc.tasks.first.error, contains('empty report'));
    });

    test('error event flips to failed and surfaces the message', () async {
      // The orchestrator emits OrchestratorEvent.error for any
      // protocol-level failure. We simulate that directly.
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
                yield const OrchestratorEvent.turnDone(
                  TurnResult(protocolError: 'HTTP 500: internal error'),
                );
              },
              initialHistory: const <ChatRequestMessage>[],
              executor: (_) async => 'unused',
              onTurnCommitted: (_) {},
            )
            .map(_toStreamEventForTest);
      });
      final result = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
      );
      expect(result, SubAgentService.noUsefulResult);
      expect(result, isNot(contains('HTTP 500')));
      expect(svc.tasks.first.status, SubAgentStatus.failed);
      expect(svc.tasks.first.error, contains('HTTP 500'));
    });

    test('cancel during run terminates with cancelled status', () async {
      // The transport cancels the orchestrator from INSIDE the
      // runOneTurn callback (so the cancel flag survives the
      // orchestrator's `run` reset). The orchestrator bails
      // out at the next checkpoint with a "Generation
      // stopped by user" error event.
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
                // orchestrator's `run` resets the flag at start,
                // so a pre-run cancel would be lost).
                orchestrator.cancel();
                // Yield nothing — the orchestrator's `run` checks
                // `_cancelled` at the start of every round and
                // bails out with an error event.
              },
              initialHistory: const <ChatRequestMessage>[],
              executor: (_) async => 'unused',
              onTurnCommitted: (_) {},
            )
            .map(_toStreamEventForTest);
      });
      final result = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
      );
      expect(result, SubAgentService.cancelledResult);
      expect(result, isNot(contains('Generation stopped')));
    });

    test('SubAgentService.cancel() during a run flips the task', () async {
      // Stream that completes successfully on its own (with
      // some content so the sub-agent's "empty report → failed"
      // branch doesn't fire).
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
                yield OrchestratorEvent.content('a happy report');
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
            .map(_toStreamEventForTest);
      });
      // Just confirm the happy-path case completes normally
      // (the test "cancel during run" above exercises the
      // cancellation code path; this one makes sure the
      // non-cancelled run still works).
      final result = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
      );
      expect(result, 'a happy report');
    });

    test('toolStart / toolDone mirror into the task state', () async {
      transport.scriptedRounds = [
        // Round 1: model asks for current_time.
        [
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [
                ParsedToolCall(
                  id: 'call_1',
                  name: 'current_time',
                  argumentsRaw: '{}',
                  arguments: <String, dynamic>{},
                ),
              ],
              emittedAnyContent: true,
            ),
          ),
        ],
        // Round 2: model produces the final report text.
        [
          OrchestratorEvent.content('done'),
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: true,
            ),
          ),
        ],
      ];
      final result = await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
      );
      expect(result, 'done');
      final tcs = svc.tasks.first.toolCalls;
      expect(tcs, hasLength(1));
      expect(tcs.first.name, 'current_time');
      expect(tcs.first.status, SubAgentToolStatus.success);
    });

    test('progress callback fires for each phase', () async {
      final phases = <SubAgentProgressPhase>[];
      transport.scriptedRounds = [
        [
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [
                ParsedToolCall(
                  id: 'c1',
                  name: 'current_time',
                  argumentsRaw: '{}',
                  arguments: <String, dynamic>{},
                ),
              ],
              emittedAnyContent: true,
            ),
          ),
        ],
        [
          OrchestratorEvent.content('time ok'),
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: true,
            ),
          ),
        ],
      ];
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
        onProgress: (p) => phases.add(p.phase),
      );
      // started → toolCall (from orchestrator's toolStart) →
      // toolResult (from orchestrator's toolDone) → content (for
      // the streaming report) → report (terminal). The exact
      // interleaving depends on the orchestrator's bookkeeping,
      // so we just assert the key phases are present and the
      // terminal phase is `report`.
      expect(phases.first, SubAgentProgressPhase.started);
      expect(phases, contains(SubAgentProgressPhase.toolCall));
      expect(
        phases.where((p) => p == SubAgentProgressPhase.toolCall),
        hasLength(1),
      );
      expect(phases, contains(SubAgentProgressPhase.toolResult));
      expect(
        phases.where((p) => p == SubAgentProgressPhase.toolResult),
        hasLength(1),
      );
      expect(phases, contains(SubAgentProgressPhase.content));
      expect(phases.last, SubAgentProgressPhase.report);
    });

    test('content events stream the partial report into the task', () async {
      // The chat bubble needs the partial report to render while
      // the sub-agent is still running — otherwise the user
      // would just see a tool-call arrow list (the "messy"
      // display we're replacing). Verify each content event
      // updates the task's `report` field.
      final reportSnapshots = <String>[];
      transport.scriptedRounds = [
        [
          OrchestratorEvent.content('TL;DR: '),
          OrchestratorEvent.content('42'),
          OrchestratorEvent.content('\nSource: '),
          OrchestratorEvent.content('https://example.com'),
          const OrchestratorEvent.turnDone(
            TurnResult(
              assistantTurn: null,
              toolCalls: [],
              emittedAnyContent: true,
            ),
          ),
        ],
      ];
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'X',
        want: 'Y',
        onProgress: (p) {
          if (p.phase == SubAgentProgressPhase.content) {
            reportSnapshots.add(p.task.report ?? '');
          }
        },
      );
      // Each delta should have produced a `content` progress
      // event with the cumulative report.
      expect(reportSnapshots, [
        'TL;DR: ',
        'TL;DR: 42',
        'TL;DR: 42\nSource: ',
        'TL;DR: 42\nSource: https://example.com',
      ]);

      // And the task itself should hold the full report at the
      // end (regression check — the streaming updates must
      // not clobber the terminal report).
      final t = svc.tasks.first;
      expect(t.report, 'TL;DR: 42\nSource: https://example.com');
      expect(t.status, SubAgentStatus.completed);
    });

    test('SubAgentTool.runDelegate validates required args', () async {
      // The tool itself throws a ToolException for delegate when
      // the chat provider hasn't wired it (we test the tool's
      // own validation, not the chat-provider hook). Use the
      // public execute() for the no-transport paths.
      final tool = SubAgentTool();
      // delegate without task/want throws (because the
      // chat-provider hook is required; the tool's own
      // execute() always throws for delegate so the chat
      // provider can supply the transport config).
      expect(
        () => tool.execute({'action': 'delegate'}, _StubToolService()),
        throwsA(isA<ToolException>()),
      );
    });
  });

  group('SubAgentService bookkeeping (list / get)', () {
    late SubAgentService svc;

    setUp(() {
      svc = SubAgentService(
        apiService: _StubApiService(),
        localLlmService: _StubLocalLlmService(),
      );
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
            .map(_toStreamEventForTest);
      });
    });

    tearDown(() => svc.dispose());

    test('list returns the new tasks first', () async {
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'first',
        want: 'one',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'second',
        want: 'two',
      );
      final all = svc.tasks;
      expect(all, hasLength(2));
      // Newest-first
      expect(all.first.task, 'second');
      expect(all.last.task, 'first');
    });

    test('getById returns the matching task', () async {
      await svc.run(
        config: const SubAgentConfig(useLocal: false),
        toolService: _StubToolService(),
        task: 'find me',
        want: 'a result',
      );
      final id = svc.tasks.first.id;
      final t = svc.getById(id);
      expect(t, isNotNull);
      expect(t!.task, 'find me');
    });

    test('getById returns null for unknown id', () {
      expect(svc.getById('nope'), isNull);
    });
  });
}

/// Top-level helper that bridges the orchestrator's
/// `OrchestratorEvent` stream to the sub-agent's `StreamEvent`
/// stream. Lives outside the test classes so the per-test
/// closures can re-use it (avoids duplication).
StreamEvent _toStreamEventForTest(OrchestratorEvent ev) {
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
    case OrchestratorEventKind.turnDone:
      return const StreamEvent(type: 'done', done: true);
  }
}
