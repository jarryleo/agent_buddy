import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/local_provider.dart';
import '../models/message.dart';
import '../models/provider.dart';
import 'api_service.dart';
import 'local_llm_service.dart';
import 'tool_orchestrator.dart';
import 'tool_service.dart';
import 'tools/tool_registry.dart';

/// Status of a sub-agent task.
enum SubAgentStatus {
  /// The sub-agent is still running (tool-calling loop in progress).
  running,

  /// The sub-agent finished and produced a final report.
  completed,

  /// The sub-agent hit a hard error (model call failed, tool round
  /// limit hit, etc.).
  failed,

  /// The sub-agent was cancelled by the main agent or by the user.
  cancelled,
}

/// A single delegation task.
@immutable
class SubAgentTask {
  const SubAgentTask({
    required this.id,
    required this.task,
    required this.want,
    required this.context,
    required this.status,
    required this.createdAt,
    this.report,
    this.error,
    this.toolCalls = const [],
    this.finishedAt,
    this.rounds = 0,
  });

  final String id;
  final String task;
  final String want;
  final String context;
  final SubAgentStatus status;
  final DateTime createdAt;
  final DateTime? finishedAt;
  final int rounds;

  /// The final compressed report the sub-agent produced. Empty
  /// until [status] flips to [SubAgentStatus.completed].
  final String? report;

  /// The last error from the sub-agent's model or tool round. Populated
  /// when [status] is [SubAgentStatus.failed].
  final String? error;

  final List<SubAgentToolCall> toolCalls;

  SubAgentTask copyWith({
    SubAgentStatus? status,
    DateTime? finishedAt,
    String? report,
    String? error,
    List<SubAgentToolCall>? toolCalls,
    int? rounds,
  }) {
    return SubAgentTask(
      id: id,
      task: task,
      want: want,
      context: context,
      status: status ?? this.status,
      createdAt: createdAt,
      finishedAt: finishedAt ?? this.finishedAt,
      report: report ?? this.report,
      error: error ?? this.error,
      toolCalls: toolCalls ?? this.toolCalls,
      rounds: rounds ?? this.rounds,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'task': task,
    'want': want,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    if (status == SubAgentStatus.completed &&
        report != null &&
        report!.trim().isNotEmpty)
      'report': report,
  };
}

@immutable
class SubAgentToolCall {
  const SubAgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    required this.status,
    this.result,
    this.error,
  });

  final String id;
  final String name;
  final String arguments;
  final SubAgentToolStatus status;
  final String? result;
  final String? error;

  SubAgentToolCall copyWith({
    SubAgentToolStatus? status,
    String? result,
    String? error,
  }) {
    return SubAgentToolCall(
      id: id,
      name: name,
      arguments: arguments,
      status: status ?? this.status,
      result: result ?? this.result,
      error: error ?? this.error,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': arguments,
    'status': status.name,
    if (result != null) 'result': result,
    if (error != null) 'error': error,
  };
}

enum SubAgentToolStatus { running, success, failed }

/// Configuration for the sub-agent transport. The same `ApiService`
/// / `LocalLlmService` instances the main agent uses are reused so
/// the user gets one place to set the API key, model, etc. — the
/// sub-agent is just a "different lane" running through the same
/// services.
@immutable
class SubAgentConfig {
  const SubAgentConfig({
    required this.useLocal,
    this.provider,
    this.localProvider,
  });

  /// `true` to run the sub-agent against the user's on-device GGUF
  /// model (llamadart). `false` to run against the configured cloud
  /// provider. The main turn's transport is mirrored so the
  /// sub-agent uses the same engine the user already paid for.
  final bool useLocal;
  final ModelProvider? provider;
  final LocalProvider? localProvider;
}

/// A snapshot of the live sub-agent — surfaced via [onProgress]
/// so the chat bubble can repaint as the sub-agent makes progress
/// (intermediate tool calls, final report, …).
@immutable
class SubAgentProgress {
  const SubAgentProgress({required this.task, required this.phase});
  final SubAgentTask task;

  /// What just changed on the task. Drives the bubble's live
  /// counter / spinner.
  final SubAgentProgressPhase phase;
}

enum SubAgentProgressPhase {
  started,
  toolCall,
  toolResult,

  /// The sub-agent is composing its final report — content tokens
  /// are streaming in. The chat UI uses this to mirror the
  /// partial report into the bubble's result panel so the user
  /// sees the actual answer (not the intermediate tool-call
  /// scratch). Emitted every time [SubAgentTask.report] grows;
  /// throttled at the chat-provider layer via the same ~80ms
  /// coalescing window as the streaming layer.
  content,
  report,
  failed,
  cancelled,
}

/// Lightweight callback used by the runner to surface sub-agent
/// progress to the chat UI without going through the main agent's
/// orchestrator. The tool wires this up in `ChatProvider` so the
/// `ToolCall` card can repaint as the sub-agent works.
typedef SubAgentProgressListener = void Function(SubAgentProgress p);

/// Pluggable per-run stream factory. Returns the
/// `Stream<StreamEvent>` the sub-agent consumes for one task.
/// Production routes through `ApiService` / `LocalLlmService`;
/// tests inject a fake to drive the runner with a scripted
/// stream of events.
typedef SubAgentStreamFactory =
    Stream<StreamEvent> Function({
      required SubAgentConfig config,
      required List<String> systemPrompts,
      required List<ChatRequestMessage> messages,
      required List<Map<String, dynamic>> tools,
      required ToolOrchestrator orchestrator,
      required Future<String> Function(Map<String, dynamic> raw) onToolCall,
    });

/// In-process sub-agent runner. The main agent delegates a
/// research / information-gathering task to this service, which
/// runs a fresh AI turn with:
///
///   * a different system prompt ("you are an isolated sub-agent…"),
///   * a curated read-only / information-gathering toolset
///     (`fetch_web`, `search`, `current_time`, `location`,
///     `memory`, `run_command`),
///   * no history from the main session,
///   * a hard cap on tool rounds and on the final report length.
///
/// The sub-agent's intermediate tool calls and intermediate
/// text are NEVER appended to the main session's message list.
/// The main agent and chat bubble only receive the report text.
///
/// One instance is held by the chat provider for the app
/// lifetime. State is in-memory only — sub-agents don't survive
/// an app kill (consistent with the runtime-only `timer` /
/// `notification` pattern; the model is told this constraint in
/// the system prompt).
class SubAgentService extends ChangeNotifier {
  static const String noUsefulResult = '子 Agent 未获得有效信息。';
  static const String cancelledResult = '子 Agent 任务已取消。';

  SubAgentService({
    required ApiService apiService,
    required LocalLlmService localLlmService,
    int maxReportChars = 12000,
    int maxToolRounds = 8,
  }) : _api = apiService,
       _localLlm = localLlmService,
       _maxReportChars = maxReportChars,
       _maxToolRounds = maxToolRounds;

  final ApiService _api;
  final LocalLlmService _localLlm;
  final int _maxReportChars;
  final int _maxToolRounds;
  final _uuid = const Uuid();

  /// Pluggable transport factory. By default routes through the
  /// injected [ApiService] / [LocalLlmService] (the production
  /// path). Tests override this with a fake that pumps a
  /// scripted `Stream<StreamEvent>` without hitting the network.
  late SubAgentStreamFactory _streamFactory = _makeDefaultStreamFactory();

  /// Override the per-run stream factory. Pass `null` to restore
  /// the production default (routes through `ApiService` /
  /// `LocalLlmService`).
  @visibleForTesting
  void setStreamFactory(SubAgentStreamFactory? factory) {
    _streamFactory = factory ?? _makeDefaultStreamFactory();
  }

  SubAgentStreamFactory _makeDefaultStreamFactory() {
    return ({
      required SubAgentConfig config,
      required List<String> systemPrompts,
      required List<ChatRequestMessage> messages,
      required List<Map<String, dynamic>> tools,
      required ToolOrchestrator orchestrator,
      required Future<String> Function(Map<String, dynamic> raw) onToolCall,
    }) {
      return _defaultStreamFactory(
        config: config,
        systemPrompts: systemPrompts,
        messages: messages,
        tools: tools,
        orchestrator: orchestrator,
        onToolCall: onToolCall,
        api: _api,
        localLlm: _localLlm,
      );
    };
  }

  /// All tasks known to the service, keyed by id. Tasks remain in
  /// memory for the app's lifetime. Newest-first.
  final Map<String, SubAgentTask> _tasks = <String, SubAgentTask>{};

  /// Per-task cancel completers. The main agent's
  /// [SubAgentService.cancel] completes the entry, which makes
  /// the in-flight `run` cancel its underlying orchestrator.
  final Map<String, _RunningSubAgent> _running = <String, _RunningSubAgent>{};

  /// Set of tool ids the sub-agent is allowed to use. Curated —
  /// the main agent's full toolset is *not* exposed. Mutating
  /// this after construction is fine (it's a defensive gate, not
  /// a hard contract).
  static const Set<String> allowedSubAgentToolIds = <String>{
    'fetch_web',
    'search',
    'current_time',
    'location',
    'memory',
    'run_command',
  };

  /// Read-only view used by the tool layer (`list` action).
  /// Newest-first.
  List<SubAgentTask> get tasks {
    final all = _tasks.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(all);
  }

  SubAgentTask? getById(String id) => _tasks[id];

  /// Cancels a running sub-agent. Idempotent — calling on a
  /// non-running task is a no-op. Cancellation is best-effort:
  /// the underlying model's current `session.create` /
  /// HTTP-stream turn finishes, but the orchestrator won't
  /// start any new rounds.
  void cancel(String id) {
    final t = _tasks[id];
    if (t == null || t.status != SubAgentStatus.running) return;
    final running = _running.remove(id);
    running?.orchestrator.cancel();
    running?.streamDone.complete();
    _emit(
      null,
      t.copyWith(
        status: SubAgentStatus.cancelled,
        finishedAt: DateTime.now(),
        error: 'cancelled by caller',
      ),
      SubAgentProgressPhase.cancelled,
    );
  }

  /// Lightweight per-tool schema builder for the sub-agent. Picks
  /// out the curated subset of tools (those in
  /// [allowedSubAgentToolIds]) from the main toolset and emits
  /// one OpenAI-style function schema per tool. We deliberately
  /// reuse the production `ToolBase.buildSchema()` so the
  /// sub-agent sees the exact same parameter shape the main agent
  /// sees — that keeps the model's behaviour predictable.
  List<Map<String, dynamic>> buildToolsSchema() {
    final out = <Map<String, dynamic>>[];
    for (final t in ToolRegistry.all) {
      if (!allowedSubAgentToolIds.contains(t.id)) continue;
      if (!t.isSupportedOnCurrentPlatform) continue;
      final schema = t.buildSchema();
      if (schema.isNotEmpty) out.add(schema);
    }
    return out;
  }

  /// Builds the sub-agent's system prompt. The prompt is
  /// deliberately long-form English even when the rest of the
  /// UI is in Chinese — the sub-agent is an internal worker, not
  /// a user-facing agent, so it makes sense to optimize for
  /// "follow the rules" over "match the user's locale". The
  /// prompt tells the model:
  ///
  ///   1. It is isolated — no prior context, no follow-up
  ///      conversation, no asking the user questions.
  ///   2. It must return a structured final report that
  ///      satisfies `want`.
  ///   3. It must compress aggressively — the main agent reads
  ///      the report and decides what to do next.
  ///   4. It must not modify the user's files, calendar,
  ///      reminders, etc. (the curated toolset already enforces
  ///      this; the prompt makes it explicit so the model
  ///      doesn't try to be clever).
  String buildSystemPrompt() {
    return 'You are an isolated sub-agent inside Agent Buddy. The main conversation '
        'agent has handed you a self-contained research task. You run in your own '
        'context window: you have no memory of prior turns, no ability to ask the '
        'user follow-up questions, and no ability to schedule notifications or '
        'modify personal data (calendar, reminders, notes, tasks, files, etc.).\n'
        '\n'
        '## How you work\n'
        '- Read the task and the `want` field carefully. The main agent will '
        'read your final report and use it as the basis for its own response, '
        'so your report IS your entire contribution.\n'
        '- Use the available tools (fetch_web / search / current_time / location '
        '/ memory / run_command) to gather what you need. You can chain them — '
        'e.g. search → fetch_web a specific URL → search again.\n'
        '- You may write to long-term memory via `memory.create` if the task '
        'explicitly says so, but do NOT modify or delete memories without '
        'explicit instruction.\n'
        '- Stop as soon as you have enough information. Do not keep digging '
        'once `want` is satisfied.\n'
        '\n'
        '## Output\n'
        '- When done, output a single concise report that satisfies `want`.\n'
        '- Lead with the answer / conclusion. Follow with supporting facts, '
        'source URLs, and any caveats.\n'
        '- Prefer bullet points over long prose. Cite sources inline (URL).\n'
        '- Include only information that helps satisfy `want`. Never include '
        'tool-call logs, failed attempts, stack traces, or raw error messages. '
        'If a limitation changes the conclusion, state it briefly without '
        'implementation details.\n'
        '- Target length: as short as possible while still complete. Hard cap '
        'on the report is enforced by the runner; if you exceed it, your '
        'report will be truncated.\n'
        '- Do NOT include any preamble like "I will now..." or "Based on '
        'my research...". Start directly with the answer.\n'
        '\n'
        '## Hard rules\n'
        '- Do not call user-facing tools (ask_user, notification, timer, '
        'download, file, google_sheet write/create_tab/delete_tab, mcp__*). '
        'They are not in your toolset; this rule is just a safety belt.\n'
        '- Do not call the subagent tool recursively.\n'
        '- Do not make up URLs, numbers, or quotes — if you cannot verify it, '
        'say so.';
  }

  /// Runs a sub-agent task and returns only its final report.
  ///
  ///   * [config] — which transport (cloud vs local) to use.
  ///   * [toolService] — the shared `ToolService` whose boxes +
  ///     HTTP client the sub-agent's tools operate on. We
  ///     deliberately reuse the *same* `ToolService` the main
  ///     agent uses so memory / notes / tasks / location are
  ///     shared (and writes the sub-agent makes persist for the
  ///     rest of the app).
  ///   * [onProgress] — optional callback fired for every
  ///     sub-agent event. Used by the chat UI to repaint the
  ///     bubble's sub-agent card.
  Future<String> run({
    required SubAgentConfig config,
    required ToolService toolService,
    required String task,
    required String want,
    String context = '',
    SubAgentProgressListener? onProgress,
  }) async {
    final id = 'sa-${_uuid.v4()}';
    final created = SubAgentTask(
      id: id,
      task: task,
      want: want,
      context: context,
      status: SubAgentStatus.running,
      createdAt: DateTime.now(),
    );
    _tasks[id] = created;
    _emit(onProgress, created, SubAgentProgressPhase.started);

    final userContent = _composeUserMessage(
      task: task,
      want: want,
      context: context,
    );
    final messages = <ChatRequestMessage>[
      ChatRequestMessage(role: MessageRole.user, content: userContent),
    ];
    final systemPrompts = <String>[buildSystemPrompt()];
    final tools = buildToolsSchema();

    final orchestrator = ToolOrchestrator(maxToolRounds: _maxToolRounds);
    final streamDone = Completer<void>();
    _running[id] = _RunningSubAgent(orchestrator, streamDone);

    final localToolCalls = <SubAgentToolCall>[];
    var report = '';
    var failed = false;
    var error = '';
    var rounds = 0;

    StreamSubscription<StreamEvent>? sub;
    try {
      final stream = _openTransportStream(
        config: config,
        systemPrompts: systemPrompts,
        messages: messages,
        tools: tools,
        orchestrator: orchestrator,
        onToolCall: (raw) =>
            _dispatchSubAgentToolCall(raw: raw, toolService: toolService),
      );

      sub = stream.listen(
        (event) {
          switch (event.type) {
            case 'toolStart':
              final callId = event.toolId ?? 'sub-${_uuid.v4()}';
              if (!localToolCalls.any((c) => c.id == callId)) {
                localToolCalls.add(
                  SubAgentToolCall(
                    id: callId,
                    name: event.toolName ?? '',
                    arguments: event.toolArguments ?? '',
                    status: SubAgentToolStatus.running,
                  ),
                );
              }
              _updateAndEmit(
                id,
                _tasks[id]!.copyWith(toolCalls: List.of(localToolCalls)),
                onProgress,
                SubAgentProgressPhase.toolCall,
              );
              break;
            case 'toolDone':
              final rawId = event.toolId ?? '';
              final idx = localToolCalls.indexWhere((c) => c.id == rawId);
              if (idx >= 0) {
                localToolCalls[idx] = localToolCalls[idx].copyWith(
                  status: (event.toolSuccess ?? false)
                      ? SubAgentToolStatus.success
                      : SubAgentToolStatus.failed,
                  result: event.toolResult,
                  error: event.toolError,
                );
              } else {
                // We didn't see the matching toolStart (rare — the
                // transport gave us a different id). Synthesize an
                // entry so the bubble stays complete.
                localToolCalls.add(
                  SubAgentToolCall(
                    id: rawId.isNotEmpty ? rawId : 'sub-${_uuid.v4()}',
                    name: event.toolName ?? '',
                    arguments: event.toolArguments ?? '',
                    status: (event.toolSuccess ?? false)
                        ? SubAgentToolStatus.success
                        : SubAgentToolStatus.failed,
                    result: event.toolResult,
                    error: event.toolError,
                  ),
                );
              }
              _updateAndEmit(
                id,
                _tasks[id]!.copyWith(toolCalls: List.of(localToolCalls)),
                onProgress,
                SubAgentProgressPhase.toolResult,
              );
              break;
            case 'content':
              if (event.contentDelta != null) {
                report += event.contentDelta!;
                // Stream the partial report into the task so the
                // chat bubble can show the sub-agent's actual
                // answer (the summary the sub-agent is composing
                // for the main agent) instead of the messy list
                // of intermediate tool calls. We deliberately do
                // NOT truncate here — the chat provider's
                // `_formatSubAgentSnapshot` already prefers the
                // longest available text and the truncation step
                // runs once at completion.
                _updateAndEmit(
                  id,
                  _tasks[id]!.copyWith(report: report),
                  onProgress,
                  SubAgentProgressPhase.content,
                );
              }
              break;
            case 'reasoning':
              // Reasoning is internal — don't surface to the bubble.
              break;
            case 'error':
              failed = true;
              error = event.error ?? 'sub-agent stream error';
              break;
            case 'done':
              rounds += 1;
              break;
          }
        },
        onError: (e) {
          failed = true;
          error = 'sub-agent stream error: $e';
        },
        onDone: () {
          if (!streamDone.isCompleted) streamDone.complete();
        },
        cancelOnError: false,
      );

      // Wait for the stream to finish naturally, OR for cancel()
      // to be called from the main agent.
      await streamDone.future;

      if (orchestrator.cancelled) {
        _updateAndEmit(
          id,
          _tasks[id]!.copyWith(
            status: SubAgentStatus.cancelled,
            finishedAt: DateTime.now(),
            toolCalls: List.of(localToolCalls),
            rounds: rounds,
          ),
          onProgress,
          SubAgentProgressPhase.cancelled,
        );
        return cancelledResult;
      }

      if (failed) {
        _updateAndEmit(
          id,
          _tasks[id]!.copyWith(
            status: SubAgentStatus.failed,
            finishedAt: DateTime.now(),
            error: error,
            toolCalls: List.of(localToolCalls),
            rounds: rounds,
          ),
          onProgress,
          SubAgentProgressPhase.failed,
        );
        return noUsefulResult;
      }

      if (report.trim().isEmpty) {
        // No content came back. The model said nothing — treat
        // as a soft failure so the main agent can react.
        _updateAndEmit(
          id,
          _tasks[id]!.copyWith(
            status: SubAgentStatus.failed,
            finishedAt: DateTime.now(),
            error: 'sub-agent produced an empty report',
            toolCalls: List.of(localToolCalls),
            rounds: rounds,
          ),
          onProgress,
          SubAgentProgressPhase.failed,
        );
        return noUsefulResult;
      }

      // Cap the report so a runaway sub-agent can't blow the main
      // agent's context window. The cap is generous (12k chars
      // by default — a long-form research summary is well under
      // 4k tokens).
      final capped = _truncate(report, _maxReportChars);
      _updateAndEmit(
        id,
        _tasks[id]!.copyWith(
          status: SubAgentStatus.completed,
          finishedAt: DateTime.now(),
          report: capped,
          toolCalls: List.of(localToolCalls),
          rounds: rounds,
        ),
        onProgress,
        SubAgentProgressPhase.report,
      );
      return capped;
    } catch (e) {
      _updateAndEmit(
        id,
        _tasks[id]!.copyWith(
          status: SubAgentStatus.failed,
          finishedAt: DateTime.now(),
          error: '$e',
          toolCalls: List.of(localToolCalls),
          rounds: rounds,
        ),
        onProgress,
        SubAgentProgressPhase.failed,
      );
      return noUsefulResult;
    } finally {
      _running.remove(id);
      await sub?.cancel();
    }
  }

  // ----------------------------------------------------------------
  // Internals
  // ----------------------------------------------------------------

  /// Opens the per-transport stream — `ApiService.streamChat` for
  /// the cloud path, `LocalLlmService.streamChat` for the local
  /// GGUF path. We pass our own [ToolOrchestrator] so cancel
  /// propagates from [SubAgentService.cancel] down to the
  /// orchestrator's loop, and we pass `onToolCall` so the
  /// orchestrator can actually execute the sub-agent's tool
  /// calls (the dispatcher routes them through the curated
  /// `ToolRegistry` and the shared `ToolService`).
  ///
  /// Production uses [setStreamFactory] with a default that
  /// routes to the live `ApiService` / `LocalLlmService`. Tests
  /// inject a fake factory that pumps scripted events.
  Stream<StreamEvent> _openTransportStream({
    required SubAgentConfig config,
    required List<String> systemPrompts,
    required List<ChatRequestMessage> messages,
    required List<Map<String, dynamic>> tools,
    required ToolOrchestrator orchestrator,
    required Future<String> Function(Map<String, dynamic> raw) onToolCall,
  }) {
    return _streamFactory(
      config: config,
      systemPrompts: systemPrompts,
      messages: messages,
      tools: tools,
      orchestrator: orchestrator,
      onToolCall: onToolCall,
    );
  }

  /// Dispatches a single sub-agent tool call. Mirrors the main
  /// agent's dispatch path in `ChatProvider._onToolCall`, but
  /// strips out everything that's specific to the main session
  /// (UI surfaces, ask_user completer, download progress). The
  /// sub-agent's toolset is curated at schema level (see
  /// [buildToolsSchema]) so the only tools that can actually
  /// reach this dispatcher are the read-only / info-gathering
  /// ones — no UI interaction is possible.
  Future<String> _dispatchSubAgentToolCall({
    required Map<String, dynamic> raw,
    required ToolService toolService,
  }) async {
    final name = raw['name'] as String? ?? '';
    final argsRaw = raw['arguments'];
    final Map<String, dynamic> args = argsRaw is Map
        ? argsRaw.cast<String, dynamic>()
        : <String, dynamic>{};
    if (!allowedSubAgentToolIds.contains(name)) {
      throw StateError(
        'sub-agent tried to call "$name" which is not in its allowed toolset',
      );
    }
    final tool = ToolRegistry.byId(name);
    if (tool == null) {
      throw StateError('sub-agent tool "$name" not found in registry');
    }
    if (!tool.isSupportedOnCurrentPlatform) {
      throw StateError(
        'sub-agent tool "$name" is not supported on this platform',
      );
    }
    return tool.execute(args, toolService);
  }

  String _composeUserMessage({
    required String task,
    required String want,
    required String context,
  }) {
    final buf = StringBuffer()
      ..writeln('# Task')
      ..writeln(task)
      ..writeln()
      ..writeln('# What the main agent wants back')
      ..writeln(want);
    if (context.trim().isNotEmpty) {
      buf
        ..writeln()
        ..writeln('# Supporting context (optional)')
        ..writeln(context);
    }
    buf
      ..writeln()
      ..writeln(
        'When done, output a single concise report. No preamble. Cite sources.',
      );
    return buf.toString();
  }

  void _updateAndEmit(
    String id,
    SubAgentTask next,
    SubAgentProgressListener? onProgress,
    SubAgentProgressPhase phase,
  ) {
    _tasks[id] = next;
    _emit(onProgress, next, phase);
  }

  void _emit(
    SubAgentProgressListener? onProgress,
    SubAgentTask task,
    SubAgentProgressPhase phase,
  ) {
    notifyListeners();
    onProgress?.call(SubAgentProgress(task: task, phase: phase));
  }

  static String _truncate(String s, int maxChars) {
    if (s.length <= maxChars) return s;
    return '${s.substring(0, maxChars)}\n\n[...truncated, ${s.length - maxChars} chars omitted]';
  }
}

/// Production default: routes through the live `ApiService` /
/// `LocalLlmService`. Tests override via [SubAgentService.setStreamFactory].
Stream<StreamEvent> _defaultStreamFactory({
  required SubAgentConfig config,
  required List<String> systemPrompts,
  required List<ChatRequestMessage> messages,
  required List<Map<String, dynamic>> tools,
  required ToolOrchestrator orchestrator,
  required Future<String> Function(Map<String, dynamic> raw) onToolCall,
  required ApiService api,
  required LocalLlmService localLlm,
}) {
  if (config.useLocal) {
    final lp = config.localProvider;
    if (lp == null) {
      throw StateError(
        'SubAgentService: useLocal=true but no local provider configured',
      );
    }
    // `boundSessionId: null` forces a fresh reset+seed on the
    // local engine so the sub-agent's conversation doesn't
    // bleed into the main agent's next turn. The main agent's
    // `setLocalSessionId` machinery still works correctly
    // because the next main turn will see `_boundSessionId ==
    // null != activeSessionId` and reset+seed again with the
    // main agent's full history.
    return localLlm.streamChat(
      provider: lp,
      systemPrompts: systemPrompts,
      messages: messages,
      tools: tools,
      onToolCall: onToolCall,
      orchestrator: orchestrator,
      boundSessionId: null,
    );
  }
  final p = config.provider;
  if (p == null) {
    throw StateError(
      'SubAgentService: useLocal=false but no cloud provider configured',
    );
  }
  return api.streamChat(
    provider: p,
    model: p.selectedModel ?? (p.models.isNotEmpty ? p.models.first : ''),
    messages: messages,
    systemPrompts: systemPrompts.isEmpty ? null : systemPrompts,
    tools: tools.isEmpty ? null : tools,
    onToolCall: onToolCall,
    orchestrator: orchestrator,
  );
}

/// Bookkeeping for one in-flight sub-agent run. Held in
/// [SubAgentService._running] so [SubAgentService.cancel] can
/// reach into the orchestrator and signal the stream listener.
class _RunningSubAgent {
  _RunningSubAgent(this.orchestrator, this.streamDone);
  final ToolOrchestrator orchestrator;
  final Completer<void> streamDone;
}
