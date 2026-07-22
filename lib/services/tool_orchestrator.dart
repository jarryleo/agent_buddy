import 'dart:async';

import '../models/message.dart';
import 'api_service.dart';

/// Events surfaced by [ToolOrchestrator.run] to the caller (chat UI).
/// Mirrors the existing `StreamEvent` vocabulary so the ChatProvider
/// listener doesn't need to change.
enum OrchestratorEventKind {
  toolStart,
  toolDone,
  content,
  reasoning,
  error,
  usage,
  turnDone,

  /// Fired at the START of each tool-calling round (zero-indexed).
  /// ChatProvider uses it to mint a fresh per-round assistant
  /// bubble so long, multi-round tool-calling sequences stop
  /// accumulating every round's content / thinking / tool cards
  /// into a single ever-growing bubble. The final round's bubble
  /// is the one that carries the user-facing answer text.
  roundStart,
}

class OrchestratorEvent {
  final OrchestratorEventKind kind;
  final String? toolId;
  final String? toolName;
  final String? toolArguments;
  final String? toolResult;
  final bool? toolSuccess;
  final String? toolError;
  final String? thinkingDelta;
  final String? contentDelta;
  final String? error;
  final TurnResult? turnResult;

  /// Zero-indexed round number. Populated by [roundStart] events
  /// only; `0` for the first round. Lets the chat UI track
  /// "which round bubble am I currently writing to" without
  /// relying on string ids.
  final int? roundIndex;

  /// Per-turn token usage, lifted off the latest `turnDone`
  /// payload when present. Only the Anthropic-protocol
  /// transport populates it today; the rest stays null and the
  /// chat UI falls back to its heuristic token estimate. See
  /// [TurnUsage] for the field semantics.
  final TurnUsage? usage;

  const OrchestratorEvent._({
    required this.kind,
    this.toolId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolSuccess,
    this.toolError,
    this.thinkingDelta,
    this.contentDelta,
    this.error,
    this.turnResult,
    this.roundIndex,
    this.usage,
  });

  /// Const-friendly sentinel constructor. The redirecting
  /// `const factory` above uses this to allow `const
  /// OrchestratorEvent.turnDone(...)` in tests and other constant
  /// contexts.
  const OrchestratorEvent._turnDoneSentinel(
    TurnResult result, {
    TurnUsage? usage,
  }) : this._(
         kind: OrchestratorEventKind.turnDone,
         turnResult: result,
         usage: usage,
       );

  factory OrchestratorEvent.toolStart({
    required String id,
    required String name,
    required String arguments,
  }) => OrchestratorEvent._(
    kind: OrchestratorEventKind.toolStart,
    toolId: id,
    toolName: name,
    toolArguments: arguments,
  );

  factory OrchestratorEvent.toolDone({
    required String id,
    required String name,
    required String result,
    required bool success,
    String? error,
  }) => OrchestratorEvent._(
    kind: OrchestratorEventKind.toolDone,
    toolId: id,
    toolName: name,
    toolResult: result,
    toolSuccess: success,
    toolError: error,
  );

  factory OrchestratorEvent.content(String delta) => OrchestratorEvent._(
    kind: OrchestratorEventKind.content,
    contentDelta: delta,
  );

  factory OrchestratorEvent.reasoning(String delta) => OrchestratorEvent._(
    kind: OrchestratorEventKind.reasoning,
    thinkingDelta: delta,
  );

  factory OrchestratorEvent.error(String error) =>
      OrchestratorEvent._(kind: OrchestratorEventKind.error, error: error);

  /// Forwarded to the chat UI as a `StreamEvent.usage` so the
  /// message-bubble footer can show real cache-hit numbers
  /// instead of the heuristic estimate. Currently only the
  /// Anthropic-protocol transport emits this.
  factory OrchestratorEvent.usage(TurnUsage usage) =>
      OrchestratorEvent._(kind: OrchestratorEventKind.usage, usage: usage);

  /// Sentinel: the per-round generator is done and produced a
  /// [TurnResult]. The orchestrator uses this to know when to stop
  /// listening to the round stream and start executing tools.
  /// The optional [usage] is surfaced by the orchestrator as a
  /// separate `usage` event before the sentinel so the chat UI
  /// sees the live token counts.
  const factory OrchestratorEvent.turnDone(TurnResult result) =
      OrchestratorEvent._turnDoneSentinel;

  /// Fired at the START of every tool-calling round (zero-indexed).
  /// ChatProvider uses it to mint a fresh per-round assistant bubble
  /// so long, multi-round sequences stop accumulating every round's
  /// content / thinking / tool cards into a single bubble.
  ///
  /// The very first round (roundIndex == 0) is signalled right
  /// after the orchestrator enters its loop; subsequent rounds are
  /// signalled before the corresponding `runOneTurn` call. Round 0
  /// is the one that starts streaming the assistant's first reply,
  /// so ChatProvider mints the initial assistant placeholder here
  /// (rather than in `_appendUserAndAssistantPlaceholders`, which
  /// now only appends the user message).
  factory OrchestratorEvent.roundStart(int roundIndex) => OrchestratorEvent._(
    kind: OrchestratorEventKind.roundStart,
    roundIndex: roundIndex,
  );
}

/// Result of a single "model turn" parsed from the underlying protocol
/// (OpenAI SSE, Anthropic SSE, or local llama). The protocol callback
/// returns one of these per round; the orchestrator uses [assistantTurn]
/// + [toolCalls] to drive the next round.
class TurnResult {
  /// The assistant message that the protocol layer just produced.
  /// The orchestrator appends this to history verbatim. It must
  /// carry the role-`assistant` content (including any tool_call /
  /// tool_use blocks) so the next round can reference it.
  final ChatRequestMessage? assistantTurn;

  /// Parsed tool calls. When empty, the orchestrator terminates the
  /// loop and reports "done".
  final List<ParsedToolCall> toolCalls;

  /// Optional protocol-level signal: the underlying transport had a
  /// fatal error (HTTP failure, malformed stream, ...). When this is
  /// non-null the orchestrator surfaces an [OrchestratorEvent.error]
  /// and stops the loop.
  final String? protocolError;

  /// Optional signal that the response was truncated (e.g. max_tokens
  /// or length). The orchestrator surfaces it as a [content] delta so
  /// the user sees a `*(truncated)*` marker.
  final bool truncated;

  /// True if the model emitted ANY content / reasoning during this
  /// turn. Used to detect "the model said nothing" — in which case
  /// we abort the loop before issuing a follow-up request that the
  /// model probably won't be able to answer either.
  final bool emittedAnyContent;

  /// Per-turn token usage as reported by the provider. Only the
  /// Anthropic-protocol transport populates this (OpenAI does not
  /// surface per-request usage on the streaming channel); for the
  /// other transports it stays null and the chat UI falls back to
  /// its heuristic token estimate.
  final TurnUsage? usage;

  const TurnResult({
    this.assistantTurn,
    this.toolCalls = const [],
    this.protocolError,
    this.truncated = false,
    this.emittedAnyContent = false,
    this.usage,
  });
}

/// Per-turn token usage, surfaced by transports that report it
/// (today: only the Anthropic-protocol cloud transport — the
/// OpenAI-protocol transport and the local LLM don't report
/// per-request usage on the streaming channel).
///
/// The shape mirrors the `usage` block the Anthropic / MiniMax
/// server emits on `message_start` (and updates on
/// `message_delta`): split into the four buckets the docs
/// describe — uncached input, cache-write, cache-read, output.
/// See
/// https://platform.minimaxi.com/docs/api-reference/anthropic-api-compatible-cache
/// for the cost/latency semantics of each.
class TurnUsage {
  final int inputTokens;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;
  final int outputTokens;

  const TurnUsage({
    required this.inputTokens,
    required this.cacheCreationInputTokens,
    required this.cacheReadInputTokens,
    required this.outputTokens,
  });

  /// Total prompt-side tokens billed this turn: uncached input
  /// + everything cached (write-on-cold, read-on-warm). Matches
  /// the docs' "total_input_tokens = cache_read_input_tokens +
  /// cache_creation_input_tokens + input_tokens" formula.
  int get totalInputTokens =>
      inputTokens + cacheCreationInputTokens + cacheReadInputTokens;

  /// True iff the prompt hit at least one cache entry on this
  /// turn (i.e. the server reused something instead of writing
  /// the entire prompt from scratch).
  bool get cacheHit => cacheReadInputTokens > 0;
}

class ParsedToolCall {
  final String id;
  final String name;
  final String argumentsRaw;
  final Map<String, dynamic> arguments;

  const ParsedToolCall({
    required this.id,
    required this.name,
    required this.argumentsRaw,
    required this.arguments,
  });
}

/// Signature for executing a single tool call. The implementation lives
/// in `ChatProvider` (so it can read l10n + drive ask_user's completer).
typedef ToolCallExecutor = Future<String> Function(ParsedToolCall call);

/// Result of a tool execution (for the orchestrator to surface in the
/// stream). `success` is false when the executor threw.
class ToolOutcome {
  final String result;
  final bool success;
  final String? error;
  const ToolOutcome(this.result, {required this.success, this.error});
  factory ToolOutcome.ok(String result) => ToolOutcome(result, success: true);
  factory ToolOutcome.fail(String result, String error) =>
      ToolOutcome(result, success: false, error: error);
}

/// Drives the multi-round tool-calling loop. The protocol layer
/// (ApiService / LocalLlmService) is reduced to "execute one turn and
/// return a [TurnResult]"; this class owns:
///
///   - looping until the model stops emitting tool calls,
///   - enforcing a hard cap on rounds (so a runaway model can't burn
///     tokens forever),
///   - surfacing the (possibly empty) content of every turn to the
///     chat UI as [OrchestratorEvent]s in the same order the model
///     produced them.
///
/// This is deliberately transport-agnostic: it knows nothing about
/// HTTP, SSE, or llama.cpp. That's why [run] takes a `runOneTurn`
/// callback supplied by the caller.
class ToolOrchestrator {
  /// Max consecutive tool-calling rounds before we give up. Default
  /// is generous enough for real work (a model that wants to fetch 3
  /// URLs and run 2 commands before answering) but small enough to
  /// bound a runaway loop.
  final int maxToolRounds;

  ToolOrchestrator({this.maxToolRounds = 100});

  /// Set to true by [cancel] so the [run] generator can stop early.
  bool _cancelled = false;

  /// True if [cancel] has been called since the last [run] started.
  /// Public read-only so callers (e.g. the sub-agent service) can
  /// distinguish a user-cancelled run from a natural completion.
  bool get cancelled => _cancelled;

  /// Signals the [run] loop to stop at the next checkpoint. Pending
  /// tool executions already in flight will still complete, but no
  /// new rounds are started.
  void cancel() {
    _cancelled = true;
  }

  /// Drives the loop. The callback [runOneTurn] receives the current
  /// message history (including any prior assistant turns and tool
  /// results) and must return a `Stream<OrchestratorEvent>` of live
  /// deltas ending with a sentinel [OrchestratorEvent.turnDone] that
  /// carries the final [TurnResult].
  ///
  /// The orchestrator `await for`s the stream, forwards every live
  /// event to its caller, and uses the [OrchestratorEvent.turnDone]
  /// payload to decide whether to keep looping.
  ///
  /// [executor] runs a single tool call (this is what eventually calls
  /// the `ToolService` or surfaces `ask_user` chips).
  ///
  /// [onTurnCommitted] is called after a turn (and its tool results,
  /// if any) are recorded. Protocol layers use it to persist the
  /// updated history.
  Stream<OrchestratorEvent> run({
    required Stream<OrchestratorEvent> Function(
      List<ChatRequestMessage> history,
    )
    runOneTurn,
    required List<ChatRequestMessage> initialHistory,
    required ToolCallExecutor executor,
    required void Function(List<ChatRequestMessage>) onTurnCommitted,
  }) async* {
    // Reset cancellation flag for this run so a previous
    // [cancel] call doesn't immediately abort the new loop.
    _cancelled = false;
    var history = List<ChatRequestMessage>.from(initialHistory);

    for (var round = 0; round < maxToolRounds; round++) {
      if (_cancelled) {
        yield OrchestratorEvent.error('Generation stopped by user');
        return;
      }
      // Emit the round boundary so the chat UI can mint a fresh
      // per-round assistant bubble. Fired BEFORE any content /
      // reasoning / tool-start events of this round so the bubble
      // is in place by the time the first chunk lands.
      yield OrchestratorEvent.roundStart(round);
      // Run one round: live-forward every event; the final
      // `turnDone` carries the parsed [TurnResult]. Each round
      // also reports its own per-request usage (today: only the
      // Anthropic-protocol transport does). We track only the
      // LATEST round's usage so the chat UI sees the snapshot
      // from the final, content-bearing turn — earlier tool-call
      // rounds tend to be partial / discarded once the tool
      // result comes back, so their usage is less meaningful for
      // the bubble footer.
      TurnResult? turn;
      TurnUsage? turnUsage;
      await for (final ev in runOneTurn(history)) {
        if (ev.kind == OrchestratorEventKind.turnDone) {
          turn = ev.turnResult;
          turnUsage = ev.usage;
        } else if (ev.kind == OrchestratorEventKind.usage && ev.usage != null) {
          // The Anthropic protocol layer surfaces a one-shot
          // `usage` event right before `turnDone`. Capture the
          // latest so we can re-emit it AFTER all tool rounds
          // finish (the final payload is the one the chat UI
          // cares about for the message-bubble footer).
          turnUsage = ev.usage;
        } else {
          yield ev;
        }
      }
      // Forward the per-turn usage to the chat UI so the
      // bubble footer can show real cache-hit numbers. We
      // emit AFTER the inner stream completes (rather than
      // immediately on the inner usage event) so callers see
      // a stable "final of this turn" snapshot.
      if (turnUsage != null) {
        yield OrchestratorEvent.usage(turnUsage);
      }
      if (turn == null) {
        // The round stream closed without a turnDone sentinel —
        // treat as a hard error so the caller can surface it.
        yield OrchestratorEvent.error(
          'Tool round ended without a turn result; aborting loop.',
        );
        return;
      }
      if (turn.protocolError != null) {
        yield OrchestratorEvent.error(turn.protocolError!);
        return;
      }

      if (turn.truncated) {
        yield OrchestratorEvent.content(
          '*(response truncated; some content may be missing)*',
        );
      }

      // Truncation guard: when the server hits `max_tokens` (or
      // `length`) mid-tool-call, the JSON streamed into
      // `tool_calls` is incomplete — every `input_json_delta` /
      // `arguments` chunk after the cut-off is missing. The
      // tool-call *shape* may be syntactically valid JSON once we
      // parse it (see `args = {'raw': argsRaw}` fallbacks in
      // `ApiService`), but the values are at best partial. If we
      // blindly execute that, the bubble reports `ok:true,
      // size:0` for an empty `file.write` and the model keeps
      // walking a workflow that silently wiped the user's data.
      //
      // Commit the partial assistant turn so the user sees the
      // truncation marker in context, then bail. We do NOT append
      // a tool-result message — most protocols reject an
      // assistant `tool_use` with no matching `tool_result` on
      // the next round, so the safe recovery is to stop the loop
      // and let the user (or model on its next user-driven turn)
      // retry.
      if (turn.truncated && turn.toolCalls.isNotEmpty) {
        if (turn.assistantTurn != null) {
          history = [...history, turn.assistantTurn!];
          onTurnCommitted(history);
        }
        // Build a human-readable summary of which calls were
        // blocked — the model and the user both want to know
        // which tool call ids were caught (especially when
        // multiple were emitted in the same turn), so the
        // message includes the id AND the tool name. Falls back
        // gracefully when ids are missing (some local-LLM
        // backends ship empty / null ids).
        final blocked = turn.toolCalls
            .map((c) => c.id.isNotEmpty ? '${c.id}:${c.name}' : c.name)
            .toList();
        yield OrchestratorEvent.error(
          'tool call(s) truncated by the server '
          '(${blocked.length} blocked: $blocked); '
          'not executing with partial input — retry with shorter '
          'content or split the write into chunks',
        );
        return;
      }

      // No tool calls → model wants to stop. Done.
      if (turn.toolCalls.isEmpty) {
        // Commit the final assistant turn (even if it has no tool
        // calls) so the chat history reflects the full exchange.
        if (turn.assistantTurn != null) {
          history = [...history, turn.assistantTurn!];
          onTurnCommitted(history);
        }
        return;
      }

      // Append the assistant turn (which carries the tool_use /
      // tool_calls blocks) to history BEFORE executing the tools.
      // Most protocols require the tool-use message to come before
      // the tool result message in the conversation; we do that here
      // explicitly.
      if (turn.assistantTurn != null) {
        history = [...history, turn.assistantTurn!];
      }

      // Execute each tool call in order, stream toolStart/toolDone
      // events, and collect the outcomes.
      final toolResults = <ChatRequestMessage>[];
      for (final call in turn.toolCalls) {
        if (_cancelled) {
          yield OrchestratorEvent.error('Generation stopped by user');
          return;
        }
        yield OrchestratorEvent.toolStart(
          id: call.id,
          name: call.name,
          arguments: call.argumentsRaw,
        );
        ToolOutcome outcome;
        try {
          final result = await executor(call);
          outcome = ToolOutcome.ok(result);
        } catch (e) {
          outcome = ToolOutcome.fail('Error: $e', e.toString());
        }
        yield OrchestratorEvent.toolDone(
          id: call.id,
          name: call.name,
          result: outcome.result,
          success: outcome.success,
          error: outcome.error,
        );
        toolResults.add(
          ChatRequestMessage(
            role: MessageRole.tool,
            content: outcome.result,
            // We piggyback the tool call id + name on the request
            // message. The protocol layer reads them from
            // `m.toolCallId` / `m.toolName` to build the payload.
            toolCallId: call.id,
            toolName: call.name,
          ),
        );
      }

      history = [...history, ...toolResults];
      onTurnCommitted(history);
    }

    yield OrchestratorEvent.error(
      'Reached tool-calling limit ($maxToolRounds rounds); stopping loop.',
    );
  }
}
