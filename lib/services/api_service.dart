import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/file_attachment.dart';
import '../models/file_type.dart';
import '../models/message.dart';
import '../models/provider.dart';
import 'tool_orchestrator.dart';

typedef ToolSchemaBuilder = Future<List<Map<String, dynamic>>> Function();

class StreamEvent {
  final String type;
  final String text;
  final String? thinkingDelta;
  final String? contentDelta;
  final String? error;
  final bool done;

  // Tool-call fields. Populated when type == 'toolStart' or 'toolDone'.
  final String? toolId;
  final String? toolName;
  final String? toolArguments;
  final String? toolResult;
  final bool? toolSuccess;
  final String? toolError;

  /// Zero-indexed round number. Populated when
  /// `type == 'roundStart'` — fired at the start of every
  /// tool-calling round by the orchestrator. ChatProvider uses it
  /// to mint a fresh per-round assistant bubble so multi-round
  /// tool-calling sequences stop stacking everything into a
  /// single ever-growing bubble. `0` for the very first round.
  final int? roundIndex;

  /// Per-turn token usage. Populated when type == 'usage' with
  /// the cumulative counts reported by the provider:
  ///   * [usageInputTokens] — uncached input tokens (i.e. the
  ///     tokens AFTER the last cache breakpoint; the count the
  ///     provider charges at the regular input rate).
  ///   * [usageCacheCreationInputTokens] — tokens WRITTEN to a
  ///     fresh cache entry on this request (charged at the
  ///     "cache write" rate). 0 on a fully-cached request.
  ///   * [usageCacheReadInputTokens] — tokens READ from a
  ///     pre-existing cache entry on this request (charged at
  ///     the discounted "cache read" rate). 0 on a cold
  ///     (cache-creation) request.
  ///   * [usageOutputTokens] — generated tokens (charged at
  ///     the output rate).
  ///
  /// Currently only the Anthropic-protocol transport emits this
  /// event (it surfaces the `usage` block carried by
  /// `message_start` and updated by `message_delta`). The
  /// OpenAI-protocol transport does not (OpenAI does not surface
  /// per-request usage in the streaming channel).
  final int? usageInputTokens;
  final int? usageCacheCreationInputTokens;
  final int? usageCacheReadInputTokens;
  final int? usageOutputTokens;

  const StreamEvent({
    required this.type,
    this.text = '',
    this.thinkingDelta,
    this.contentDelta,
    this.error,
    this.done = false,
    this.toolId,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.toolSuccess,
    this.toolError,
    this.roundIndex,
    this.usageInputTokens,
    this.usageCacheCreationInputTokens,
    this.usageCacheReadInputTokens,
    this.usageOutputTokens,
  });

  factory StreamEvent.error(String msg) =>
      StreamEvent(type: 'error', error: msg);
  factory StreamEvent.done() => const StreamEvent(type: 'done', done: true);

  /// Fired at the start of every tool-calling round. ChatProvider
  /// uses it to mint a fresh per-round assistant bubble. Round 0
  /// is the first round; intermediate rounds index 1, 2, ...
  factory StreamEvent.roundStart(int roundIndex) =>
      StreamEvent(type: 'roundStart', roundIndex: roundIndex);
  factory StreamEvent.toolStart({
    required String id,
    required String name,
    required String arguments,
  }) => StreamEvent(
    type: 'toolStart',
    toolId: id,
    toolName: name,
    toolArguments: arguments,
  );
  factory StreamEvent.toolDone({
    required String id,
    required String name,
    required String result,
    required bool success,
    String? error,
  }) => StreamEvent(
    type: 'toolDone',
    toolId: id,
    toolName: name,
    toolResult: result,
    toolSuccess: success,
    toolError: error,
  );

  /// Emitted exactly once per assistant turn on transports that
  /// surface per-request usage (currently only Anthropic). The
  /// [usageOutputTokens] is the final value (streamed deltas
  /// don't carry it; the value lands on the terminal `message_delta`
  /// event). The cache fields reflect the state at the end of
  /// the request.
  factory StreamEvent.usage({
    required int inputTokens,
    required int cacheCreationInputTokens,
    required int cacheReadInputTokens,
    required int outputTokens,
  }) => StreamEvent(
    type: 'usage',
    usageInputTokens: inputTokens,
    usageCacheCreationInputTokens: cacheCreationInputTokens,
    usageCacheReadInputTokens: cacheReadInputTokens,
    usageOutputTokens: outputTokens,
  );
}

class ChatRequestMessage {
  final MessageRole role;
  final String content;
  final String thinking;

  /// Pre-converted `data:image/...;base64,...` URLs for any images
  /// attached to a user message. Empty for text-only messages and for
  /// non-user roles.
  final List<String> imageDataUrls;

  /// Local filesystem paths for any images attached to a user message.
  /// Used by the local LLM service which can read images directly from
  /// disk instead of decoding base64 data URLs.
  final List<String> imagePaths;
  final List<PreparedFileAttachment> fileAttachments;

  /// For tool-result messages only: the id of the tool call this
  /// result is responding to. Protocol layers (OpenAI / Anthropic)
  /// read this to build the `tool_call_id` / `tool_use_id` field.
  final String? toolCallId;

  /// For tool-result messages only: the name of the tool that produced
  /// this result. Some local LLM backends (llamadart) require it on
  /// the tool message itself.
  final String? toolName;

  /// OpenAI-only: pre-built `tool_calls` array to attach to an
  /// assistant message in a follow-up turn. When non-null,
  /// `_buildOpenAIMessages` writes it directly into the wire payload
  /// (otherwise it would be impossible to replay a tool call without
  /// re-decoding the SSE stream).
  final List<Map<String, dynamic>>? toolCallsWire;

  /// Anthropic-only: pre-built `content` array (with `tool_use`
  /// blocks) to attach to an assistant message in a follow-up turn.
  /// Mirrors [toolCallsWire] for Anthropic.
  final List<Map<String, dynamic>>? anthropicContentBlocks;

  const ChatRequestMessage({
    required this.role,
    required this.content,
    this.thinking = '',
    this.imageDataUrls = const [],
    this.imagePaths = const [],
    this.fileAttachments = const [],
    this.toolCallId,
    this.toolName,
    this.toolCallsWire,
    this.anthropicContentBlocks,
  });
}

class ApiService {
  ApiService({http.Client? client})
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Future<bool> testConnection(ModelProvider provider) async {
    try {
      switch (provider.protocol) {
        case ProviderProtocol.openai:
          return await _testOpenAI(provider);
        case ProviderProtocol.anthropic:
          return await _testAnthropic(provider);
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _testOpenAI(ModelProvider provider) async {
    final base = provider.baseUrl.endsWith('/')
        ? provider.baseUrl.substring(0, provider.baseUrl.length - 1)
        : provider.baseUrl;
    final url = Uri.parse('$base/v1/models');
    final headers = _openAIHeaders(provider);
    final resp = await _client
        .get(url, headers: headers)
        .timeout(const Duration(seconds: 15));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  }

  Future<bool> _testAnthropic(ModelProvider provider) async {
    final base = provider.baseUrl.endsWith('/')
        ? provider.baseUrl.substring(0, provider.baseUrl.length - 1)
        : provider.baseUrl;
    final url = Uri.parse('$base/v1/models');
    final headers = _anthropicHeaders(provider);
    final resp = await _client
        .get(url, headers: headers)
        .timeout(const Duration(seconds: 15));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  }

  Map<String, String> _openAIHeaders(ModelProvider provider) {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${provider.apiKey}',
    };
  }

  Map<String, String> _anthropicHeaders(ModelProvider provider) {
    return {
      'Content-Type': 'application/json',
      'x-api-key': provider.apiKey,
      'anthropic-version': '2023-06-01',
    };
  }

  Future<List<String>> fetchModels(ModelProvider provider) async {
    final base = provider.baseUrl.endsWith('/')
        ? provider.baseUrl.substring(0, provider.baseUrl.length - 1)
        : provider.baseUrl;
    final url = Uri.parse('$base/v1/models');
    final headers = provider.protocol == ProviderProtocol.openai
        ? _openAIHeaders(provider)
        : _anthropicHeaders(provider);
    final resp = await _client
        .get(url, headers: headers)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    final data =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final list = (data['data'] as List?) ?? const [];
    final models = <String>[];
    for (final item in list) {
      if (item is Map && item['id'] is String) {
        models.add(item['id'] as String);
      }
    }
    models.sort();
    return models;
  }

  /// Streams chat completion. Yields StreamEvent chunks.
  /// If [onToolCall] is provided, the underlying protocol layer
  /// is wrapped in a [ToolOrchestrator] that drives the multi-round
  /// tool-calling loop (with a hard cap on rounds). The final
  /// [StreamEvent.done] is yielded after the conversation is complete.
  ///
  /// [inlineFileTypes] is the file categories the model accepts
  /// inline (as base64 file_data / image parts). Files whose
  /// category isn't in this set are forwarded as path-only
  /// references so the model can pull them via the file tool.
  /// `null` falls back to "inline everything" — the legacy wire
  /// format used by every test in this repo and by every cloud
  /// provider that pre-dates the supported-types UI.
  Stream<StreamEvent> streamChat({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    List<String>? systemPrompts,
    List<Map<String, dynamic>>? tools,
    ToolSchemaBuilder? toolsBuilder,
    bool enableThinking = false,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
    ToolOrchestrator? orchestrator,
    Set<AgentFileType>? inlineFileTypes,
  }) async* {
    // Without an executor there's no point in the orchestrator — the
    // model can't actually call any tools, so we just do a single
    // turn.
    if (onToolCall == null) {
      final resolvedTools = toolsBuilder == null ? tools : await toolsBuilder();
      yield* _streamSingleTurn(
        provider: provider,
        model: model,
        messages: messages,
        systemPrompts: systemPrompts,
        tools: resolvedTools,
        enableThinking: enableThinking,
        inlineFileTypes: inlineFileTypes,
      );
      return;
    }

    final orch = orchestrator ?? ToolOrchestrator();
    // Working copy of the request history; the protocol layer mutates
    // it across rounds (appending the assistant turn + tool messages).
    final history = List<ChatRequestMessage>.from(messages);

    // Forward every orchestrator event to the chat UI as a
    // StreamEvent. The protocol layer (called via [runOneTurn])
    // already streams its content / reasoning deltas, so the UI sees
    // the live token stream without waiting for a full round to
    // complete.
    Stream<OrchestratorEvent> runOneTurn(List<ChatRequestMessage> h) async* {
      final roundTools = toolsBuilder == null ? tools : await toolsBuilder();
      switch (provider.protocol) {
        case ProviderProtocol.openai:
          yield* _runOpenAITurn(
            provider: provider,
            model: model,
            history: h,
            systemPrompts: systemPrompts,
            tools: roundTools,
            enableThinking: enableThinking,
            inlineFileTypes: inlineFileTypes,
          );
          return;
        case ProviderProtocol.anthropic:
          yield* _runAnthropicTurn(
            provider: provider,
            model: model,
            history: h,
            systemPrompts: systemPrompts,
            tools: roundTools,
            enableThinking: enableThinking,
            inlineFileTypes: inlineFileTypes,
          );
          return;
      }
    }

    await for (final ev in orch.run(
      runOneTurn: runOneTurn,
      initialHistory: history,
      executor: (call) async {
        // The protocol layer doesn't know about the l10n-aware
        // wrapping in ChatProvider; we throw raw here and let the
        // orchestrator prefix it with "Error: " for the model. The
        // UI side gets the error from the toolDone event.
        return onToolCall({
          'id': call.id,
          'name': call.name,
          'arguments': call.arguments,
        });
      },
      onTurnCommitted: (_) {},
    )) {
      switch (ev.kind) {
        case OrchestratorEventKind.content:
          yield StreamEvent(type: 'content', contentDelta: ev.contentDelta);
          break;
        case OrchestratorEventKind.reasoning:
          yield StreamEvent(type: 'reasoning', thinkingDelta: ev.thinkingDelta);
          break;
        case OrchestratorEventKind.toolStart:
          yield StreamEvent.toolStart(
            id: ev.toolId!,
            name: ev.toolName!,
            arguments: ev.toolArguments ?? '',
          );
          break;
        case OrchestratorEventKind.toolDone:
          yield StreamEvent.toolDone(
            id: ev.toolId!,
            name: ev.toolName!,
            result: ev.toolResult ?? '',
            success: ev.toolSuccess ?? false,
            error: ev.toolError,
          );
          break;
        case OrchestratorEventKind.error:
          yield StreamEvent(type: 'error', error: ev.error);
          break;
        case OrchestratorEventKind.usage:
          // Forward the per-turn token usage as a
          // [StreamEvent.usage]. Currently only the
          // Anthropic-protocol transport populates it; OpenAI
          // / local transports leave it null and the event is
          // never emitted.
          final u = ev.usage;
          if (u != null) {
            yield StreamEvent.usage(
              inputTokens: u.inputTokens,
              cacheCreationInputTokens: u.cacheCreationInputTokens,
              cacheReadInputTokens: u.cacheReadInputTokens,
              outputTokens: u.outputTokens,
            );
          }
          break;
        case OrchestratorEventKind.roundStart:
          // Boundary marker so ChatProvider can mint a fresh
          // per-round assistant bubble. Forwarded as a
          // `StreamEvent.roundStart` carrying the zero-indexed
          // round number.
          yield StreamEvent.roundStart(ev.roundIndex ?? 0);
          break;
        case OrchestratorEventKind.turnDone:
          // Internal sentinel; never forwarded to the chat UI.
          break;
      }
    }
    yield StreamEvent.done();
  }

  /// Single-turn (no tool calling) streaming. Used when the caller
  /// doesn't pass an [onToolCall] — i.e. tools aren't actually wired
  /// up. Mirrors the pre-orchestrator behavior of `_streamOpenAI` /
  /// `_streamAnthropic` for the "model just chats" case.
  Stream<StreamEvent> _streamSingleTurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    List<String>? systemPrompts,
    List<Map<String, dynamic>>? tools,
    required bool enableThinking,
    Set<AgentFileType>? inlineFileTypes,
  }) async* {
    switch (provider.protocol) {
      case ProviderProtocol.openai:
        yield* _streamOpenAISingleTurn(
          provider: provider,
          model: model,
          messages: messages,
          systemPrompts: systemPrompts,
          tools: tools,
          enableThinking: enableThinking,
          inlineFileTypes: inlineFileTypes,
        );
        break;
      case ProviderProtocol.anthropic:
        yield* _streamAnthropicSingleTurn(
          provider: provider,
          model: model,
          messages: messages,
          systemPrompts: systemPrompts,
          tools: tools,
          enableThinking: enableThinking,
          inlineFileTypes: inlineFileTypes,
        );
        break;
    }
  }

  Stream<StreamEvent> _streamOpenAISingleTurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    List<String>? systemPrompts,
    List<Map<String, dynamic>>? tools,
    required bool enableThinking,
    Set<AgentFileType>? inlineFileTypes,
  }) async* {
    // Backward-compat wrapper: run a single turn, ignore any tool
    // calls the model emits, just stream the text. (No orchestrator
    // involved.)
    TurnResult? finalResult;
    await for (final ev in _runOpenAITurn(
      provider: provider,
      model: model,
      history: messages,
      systemPrompts: systemPrompts,
      tools: tools,
      enableThinking: enableThinking,
      inlineFileTypes: inlineFileTypes,
    )) {
      if (ev.kind == OrchestratorEventKind.turnDone) {
        finalResult = ev.turnResult;
      } else if (ev.kind == OrchestratorEventKind.content &&
          ev.contentDelta != null) {
        yield StreamEvent(type: 'content', contentDelta: ev.contentDelta);
      } else if (ev.kind == OrchestratorEventKind.reasoning &&
          ev.thinkingDelta != null) {
        yield StreamEvent(type: 'reasoning', thinkingDelta: ev.thinkingDelta);
      }
    }
    if (finalResult?.protocolError != null) {
      yield StreamEvent.error(finalResult!.protocolError!);
    }
    yield StreamEvent.done();
  }

  /// Runs a single OpenAI turn. Streams live deltas (content /
  /// reasoning) as `OrchestratorEvent`s, and ends with a
  /// `OrchestratorEvent.turnDone` carrying the parsed [TurnResult].
  /// The orchestrator forwards every event to its caller, so the
  /// chat UI sees the live token stream the same way as before the
  /// refactor.
  Stream<OrchestratorEvent> _runOpenAITurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> history,
    required List<String>? systemPrompts,
    required List<Map<String, dynamic>>? tools,
    required bool enableThinking,
    Set<AgentFileType>? inlineFileTypes,
  }) async* {
    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'messages': _buildOpenAIMessages(history, systemPrompts, inlineFileTypes),
    };
    _applyOpenAIThinking(payload, model, enableThinking);
    if (tools != null && tools.isNotEmpty) {
      payload['tools'] = tools;
    }

    final req = http.Request('POST', Uri.parse(provider.fullChatUrl))
      ..headers.addAll(_openAIHeaders(provider))
      ..body = jsonEncode(payload);

    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req);
    } catch (e) {
      yield OrchestratorEvent.turnDone(TurnResult(protocolError: '$e'));
      return;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = await resp.stream.bytesToString();
      yield OrchestratorEvent.turnDone(
        TurnResult(protocolError: 'HTTP ${resp.statusCode}: $body'),
      );
      return;
    }

    final toolCalls = <int, _OpenAIToolCallAccumulator>{};
    String? finishReason;
    var currentContent = '';
    var currentReasoning = '';
    var anyContent = false;

    void emitContent(String chunk) {
      currentContent += chunk;
      anyContent = true;
    }

    void emitReasoning(String chunk) {
      currentReasoning += chunk;
      anyContent = true;
    }

    await for (final line
        in resp.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') {
        break;
      }
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final choice = choices.first as Map<String, dynamic>;
        final delta = choice['delta'] as Map<String, dynamic>?;
        if (delta == null) continue;

        if (finishReason == null && choice['finish_reason'] is String) {
          finishReason = choice['finish_reason'] as String;
        }

        final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          emitReasoning(reasoning);
          yield OrchestratorEvent.reasoning(reasoning);
        }

        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          emitContent(content);
          yield OrchestratorEvent.content(content);
        }
        // `refusal` is how OpenAI surfaces a safety/policy
        // refusal. Surface it as content so the user sees the
        // reason rather than a silent empty bubble.
        final refusal = delta['refusal'];
        if (refusal is String && refusal.isNotEmpty) {
          emitContent(refusal);
          yield OrchestratorEvent.content(refusal);
        }

        final tc = delta['tool_calls'];
        if (tc is List) {
          for (final raw in tc) {
            if (raw is! Map) continue;
            final map = raw;
            final index = (map['index'] as int?) ?? 0;
            final acc = toolCalls.putIfAbsent(
              index,
              () => _OpenAIToolCallAccumulator(),
            );
            if (map['id'] is String) acc.id = map['id'] as String;
            final fn = map['function'];
            if (fn is Map) {
              if (fn['name'] is String) acc.name = (fn['name'] as String);
              if (fn['arguments'] is String) {
                acc.arguments =
                    (acc.arguments ?? '') + (fn['arguments'] as String);
              }
            }
          }
        }
      } catch (_) {
        // ignore malformed chunks
      }
    }

    final parsedCalls = <ParsedToolCall>[];
    final toolCallsWire = <Map<String, dynamic>>[];
    for (final acc in toolCalls.values) {
      final name = acc.name ?? '';
      final args = acc.arguments ?? '';
      final id = acc.id ?? '';
      Map<String, dynamic> argsJson;
      try {
        argsJson = (jsonDecode(args) as Map<String, dynamic>);
      } catch (_) {
        argsJson = {'raw': args};
      }
      parsedCalls.add(
        ParsedToolCall(
          id: id,
          name: name,
          argumentsRaw: args,
          arguments: argsJson,
        ),
      );
      toolCallsWire.add({
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': args},
      });
    }

    // Build the assistant turn. The OpenAI wire format for the
    // assistant message in a follow-up turn is:
    //   {
    //     "role": "assistant",
    //     "content": <text or null>,
    //     "tool_calls": [ ... ]
    //   }
    // We piggyback this on a `ChatRequestMessage` with a special
    // `toolCallsWire` field that `_buildOpenAIMessages` will read
    // when building the next round's payload.
    final assistantTurn = ChatRequestMessage(
      role: MessageRole.assistant,
      content: currentContent,
      thinking: currentReasoning,
      toolCallsWire: toolCallsWire.isEmpty ? null : toolCallsWire,
    );

    // Special-case refusal: the model wanted to answer but the API
    // filtered it. Surface as protocolError so the orchestrator
    // bails and the chat UI shows the message.
    if (finishReason == 'content_filter') {
      yield OrchestratorEvent.turnDone(
        TurnResult(
          assistantTurn: assistantTurn,
          protocolError: 'Response was filtered by the API',
          emittedAnyContent: anyContent,
        ),
      );
      return;
    }

    yield OrchestratorEvent.turnDone(
      TurnResult(
        assistantTurn: assistantTurn,
        toolCalls: parsedCalls,
        truncated: finishReason == 'length',
        emittedAnyContent: anyContent,
      ),
    );
  }

  Stream<StreamEvent> _streamAnthropicSingleTurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    List<String>? systemPrompts,
    List<Map<String, dynamic>>? tools,
    required bool enableThinking,
    Set<AgentFileType>? inlineFileTypes,
  }) async* {
    // Backward-compat wrapper: run a single turn, ignore any tool
    // calls the model emits, just stream the text. (No orchestrator
    // involved.)
    TurnResult? finalResult;
    await for (final ev in _runAnthropicTurn(
      provider: provider,
      model: model,
      history: messages,
      systemPrompts: systemPrompts,
      tools: tools,
      enableThinking: enableThinking,
      inlineFileTypes: inlineFileTypes,
    )) {
      if (ev.kind == OrchestratorEventKind.turnDone) {
        finalResult = ev.turnResult;
      } else if (ev.kind == OrchestratorEventKind.content &&
          ev.contentDelta != null) {
        yield StreamEvent(type: 'content', contentDelta: ev.contentDelta);
      } else if (ev.kind == OrchestratorEventKind.reasoning &&
          ev.thinkingDelta != null) {
        yield StreamEvent(type: 'reasoning', thinkingDelta: ev.thinkingDelta);
      } else if (ev.kind == OrchestratorEventKind.usage && ev.usage != null) {
        // Same usage forwarding as the orchestrator path so
        // the single-turn chat (no tools wired up) still
        // surfaces real per-request token usage + cache hits
        // to the bubble footer.
        final u = ev.usage!;
        yield StreamEvent.usage(
          inputTokens: u.inputTokens,
          cacheCreationInputTokens: u.cacheCreationInputTokens,
          cacheReadInputTokens: u.cacheReadInputTokens,
          outputTokens: u.outputTokens,
        );
      }
    }
    if (finalResult?.protocolError != null) {
      yield StreamEvent.error(finalResult!.protocolError!);
    }
    yield StreamEvent.done();
  }

  /// Runs a single Anthropic turn. Streams live deltas as
  /// `OrchestratorEvent`s and ends with a `OrchestratorEvent.turnDone`
  /// carrying the parsed [TurnResult].
  Stream<OrchestratorEvent> _runAnthropicTurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> history,
    required List<String>? systemPrompts,
    required List<Map<String, dynamic>>? tools,
    required bool enableThinking,
    Set<AgentFileType>? inlineFileTypes,
  }) async* {
    // Active prompt-cache toggle. The user opts in per provider
    // (default off) — when off, every `cache_control` marker is
    // suppressed and the wire is byte-identical to the
    // pre-caching behaviour. When on, the layer below adds
    // `cache_control: {type: ephemeral}` to the last tool, the
    // last system block, and the last user-message block — see
    // https://platform.minimaxi.com/docs/api-reference/anthropic-api-compatible-cache
    // for the auto-prefix-matching rules.
    final promptCacheEnabled = provider.promptCacheEnabled;

    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'max_tokens': 4096,
      'messages': _buildAnthropicMessages(
        history,
        inlineFileTypes,
        promptCacheEnabled: promptCacheEnabled,
      ),
    };
    if (enableThinking) {
      payload['thinking'] = {'type': 'enabled', 'budget_tokens': 2048};
    }
    if (systemPrompts != null && systemPrompts.isNotEmpty) {
      if (!promptCacheEnabled) {
        // Preserve the legacy flat-string wire format. The
        // array-of-blocks form only carries cache_control
        // markers; with caching off we want byte-identical
        // compatibility with the pre-prompt-cache behaviour.
        // Anthropic supports both shapes, so this is purely a
        // compatibility choice (some downstream proxies / log
        // shippers key off the flat-string variant).
        payload['system'] = systemPrompts.join('\n\n');
      } else {
        // Anthropic's `system` field accepts either a plain
        // string or an array of typed content blocks. The block
        // form is the only way to attach `cache_control` to a
        // specific system chunk, so when prompt caching is on
        // we emit the block form. Per the MiniMax / Anthropic
        // docs, "you only need a single cache breakpoint at the
        // end of the static content and the system finds the
        // longest matching prefix" — so we mark just the FINAL
        // block; the server then walks back up to 20 blocks
        // looking for a cache hit.
        final blocks = <Map<String, dynamic>>[];
        for (var i = 0; i < systemPrompts.length; i++) {
          final block = <String, dynamic>{
            'type': 'text',
            'text': systemPrompts[i],
          };
          if (i == systemPrompts.length - 1) {
            block['cache_control'] = const {'type': 'ephemeral'};
          }
          blocks.add(block);
        }
        payload['system'] = blocks;
      }
    }
    if (tools != null && tools.isNotEmpty) {
      payload['tools'] = _toAnthropicTools(
        tools,
        markLastForCache: promptCacheEnabled,
      );
    }

    final req = http.Request('POST', Uri.parse(provider.fullChatUrl))
      ..headers.addAll(_anthropicHeaders(provider))
      ..body = jsonEncode(payload);

    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req);
    } catch (e) {
      yield OrchestratorEvent.turnDone(TurnResult(protocolError: '$e'));
      return;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final body = await resp.stream.bytesToString();
      yield OrchestratorEvent.turnDone(
        TurnResult(protocolError: 'HTTP ${resp.statusCode}: $body'),
      );
      return;
    }

    final toolUseBlocks = <Map<String, dynamic>>[];
    var currentStopReason = '';
    var currentContent = '';
    var currentReasoning = '';
    var currentThinkingSignature = '';
    var anyContent = false;

    // Usage fields collected from the Anthropic stream. The
    // server sends the cumulative input/cache counts on
    // `message_start`, then updates `output_tokens` on the
    // terminal `message_delta`. We track both so the final
    // StreamEvent carries a complete picture.
    var usageInputTokens = 0;
    var usageCacheCreationInputTokens = 0;
    var usageCacheReadInputTokens = 0;
    var usageOutputTokens = 0;

    void emitContent(String chunk) {
      currentContent += chunk;
      anyContent = true;
    }

    void emitReasoning(String chunk) {
      currentReasoning += chunk;
      anyContent = true;
    }

    await for (final line
        in resp.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) continue;
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data.isEmpty) continue;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final type = json['type'] as String?;
        switch (type) {
          case 'message_start':
            // The very first SSE event. Carries the initial
            // input-token + cache-token counts in `message.usage`.
            // Per the docs, the `output_tokens` field is also
            // present but always 0 here — the server fills it in
            // on the terminal `message_delta` instead.
            final message = json['message'] as Map<String, dynamic>?;
            final usage = message?['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              usageInputTokens = (usage['input_tokens'] as num?)?.toInt() ?? 0;
              usageCacheCreationInputTokens =
                  (usage['cache_creation_input_tokens'] as num?)?.toInt() ?? 0;
              usageCacheReadInputTokens =
                  (usage['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
              usageOutputTokens =
                  (usage['output_tokens'] as num?)?.toInt() ?? 0;
            }
            break;
          case 'content_block_start':
            final block = json['content_block'] as Map<String, dynamic>?;
            if (block != null && block['type'] == 'tool_use') {
              toolUseBlocks.add({
                'id': block['id'],
                'name': block['name'],
                'input': '',
              });
            }
            break;
          case 'content_block_delta':
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta == null) break;
            final deltaType = delta['type'];
            if (deltaType == 'thinking_delta') {
              final text = delta['thinking'];
              if (text is String && text.isNotEmpty) {
                emitReasoning(text);
                yield OrchestratorEvent.reasoning(text);
              }
            } else if (deltaType == 'signature_delta') {
              final signature = delta['signature'];
              if (signature is String && signature.isNotEmpty) {
                currentThinkingSignature += signature;
              }
            } else if (deltaType == 'text_delta') {
              final text = delta['text'];
              if (text is String && text.isNotEmpty) {
                emitContent(text);
                yield OrchestratorEvent.content(text);
              }
            } else if (deltaType == 'input_json_delta') {
              if (toolUseBlocks.isNotEmpty) {
                final last = toolUseBlocks.last;
                last['input'] =
                    (last['input'] as String) +
                    (delta['partial_json'] as String? ?? '');
              }
            }
            break;
          case 'message_delta':
            // The server emits one or more `message_delta` events
            // before `message_stop`. The `stop_reason` lands on
            // the first one; the final usage snapshot (with the
            // now-final `output_tokens`) lands on the LAST one.
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['stop_reason'] is String) {
              currentStopReason = delta['stop_reason'] as String;
            }
            final usage = json['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              usageOutputTokens =
                  (usage['output_tokens'] as num?)?.toInt() ??
                  usageOutputTokens;
              // The server also re-broadcasts input/cache counts
              // here in some implementations; prefer them so the
              // final tally is the server's most recent view.
              usageInputTokens =
                  (usage['input_tokens'] as num?)?.toInt() ?? usageInputTokens;
              usageCacheCreationInputTokens =
                  (usage['cache_creation_input_tokens'] as num?)?.toInt() ??
                  usageCacheCreationInputTokens;
              usageCacheReadInputTokens =
                  (usage['cache_read_input_tokens'] as num?)?.toInt() ??
                  usageCacheReadInputTokens;
            }
            break;
        }
      } catch (_) {
        // ignore malformed chunks
      }
    }

    // If the model wanted to call tools but stop_reason wasn't
    // 'tool_use' (rare: stop_sequence / refusal / max_tokens
    // mid-tool-block), we still surface the parsed tool calls so
    // the orchestrator can execute them. stop_reason is mostly
    // advisory here.
    final parsedCalls = <ParsedToolCall>[];
    final contentBlocks = <Map<String, dynamic>>[];
    for (final tb in toolUseBlocks) {
      final name = tb['name'] as String? ?? '';
      final id = tb['id'] as String? ?? '';
      final argsRaw = tb['input'] as String? ?? '';
      Map<String, dynamic> args;
      try {
        args = (jsonDecode(argsRaw) as Map<String, dynamic>);
      } catch (_) {
        args = {'raw': argsRaw};
      }
      parsedCalls.add(
        ParsedToolCall(
          id: id,
          name: name,
          argumentsRaw: argsRaw,
          arguments: args,
        ),
      );
      contentBlocks.add({
        'type': 'tool_use',
        'id': id,
        'name': name,
        'input': args,
      });
    }

    if (currentContent.isNotEmpty) {
      contentBlocks.insert(0, {'type': 'text', 'text': currentContent});
    }
    if (currentReasoning.isNotEmpty && currentThinkingSignature.isNotEmpty) {
      contentBlocks.insert(0, {
        'type': 'thinking',
        'thinking': currentReasoning,
        'signature': currentThinkingSignature,
      });
    }

    final hasBlocks = contentBlocks.isNotEmpty;
    final assistantTurn = ChatRequestMessage(
      role: MessageRole.assistant,
      content: currentContent,
      thinking: currentReasoning,
      anthropicContentBlocks: hasBlocks ? contentBlocks : null,
    );

    if (currentStopReason == 'refusal') {
      // Emit the per-turn usage first so callers that only
      // listen for usage events (e.g. the single-turn chat
      // path that bypasses the orchestrator) still see the
      // snapshot.
      yield OrchestratorEvent.usage(
        TurnUsage(
          inputTokens: usageInputTokens,
          cacheCreationInputTokens: usageCacheCreationInputTokens,
          cacheReadInputTokens: usageCacheReadInputTokens,
          outputTokens: usageOutputTokens,
        ),
      );
      yield OrchestratorEvent.turnDone(
        TurnResult(
          assistantTurn: assistantTurn,
          protocolError: 'Response was refused by the API',
          emittedAnyContent: anyContent,
          usage: TurnUsage(
            inputTokens: usageInputTokens,
            cacheCreationInputTokens: usageCacheCreationInputTokens,
            cacheReadInputTokens: usageCacheReadInputTokens,
            outputTokens: usageOutputTokens,
          ),
        ),
      );
      return;
    }

    // Surface the per-turn usage BEFORE the turnDone sentinel
    // so callers (orchestrator AND single-turn path) see a
    // live snapshot. The orchestrator captures this for its
    // own re-emission; the single-turn path forwards it
    // directly as a StreamEvent.usage.
    yield OrchestratorEvent.usage(
      TurnUsage(
        inputTokens: usageInputTokens,
        cacheCreationInputTokens: usageCacheCreationInputTokens,
        cacheReadInputTokens: usageCacheReadInputTokens,
        outputTokens: usageOutputTokens,
      ),
    );
    yield OrchestratorEvent.turnDone(
      TurnResult(
        assistantTurn: assistantTurn,
        toolCalls: parsedCalls,
        truncated: currentStopReason == 'max_tokens',
        emittedAnyContent: anyContent,
        usage: TurnUsage(
          inputTokens: usageInputTokens,
          cacheCreationInputTokens: usageCacheCreationInputTokens,
          cacheReadInputTokens: usageCacheReadInputTokens,
          outputTokens: usageOutputTokens,
        ),
      ),
    );
  }

  @visibleForTesting
  List<Map<String, dynamic>> buildOpenAIMessagesForTest(
    List<ChatRequestMessage> messages,
    List<String>? systemPrompts, [
    Set<AgentFileType>? inlineFileTypes,
  ]) => _buildOpenAIMessages(messages, systemPrompts, inlineFileTypes);

  @visibleForTesting
  List<Map<String, dynamic>> buildAnthropicMessagesForTest(
    List<ChatRequestMessage> messages, [
    Set<AgentFileType>? inlineFileTypes,
    bool promptCacheEnabled = false,
  ]) => _buildAnthropicMessages(
    messages,
    inlineFileTypes,
    promptCacheEnabled: promptCacheEnabled,
  );

  List<Map<String, dynamic>> _buildOpenAIMessages(
    List<ChatRequestMessage> messages,
    List<String>? systemPrompts,
    Set<AgentFileType>? inlineFileTypes,
  ) {
    final out = <Map<String, dynamic>>[];
    if (systemPrompts != null) {
      for (final p in systemPrompts) {
        if (p.isNotEmpty) {
          out.add({'role': 'system', 'content': p});
        }
      }
    }
    for (final m in messages) {
      switch (m.role) {
        case MessageRole.user:
          if (m.imageDataUrls.isNotEmpty || m.fileAttachments.isNotEmpty) {
            final parts = <Map<String, dynamic>>[];
            if (m.content.isNotEmpty) {
              parts.add({'type': 'text', 'text': m.content});
            }
            for (final file in m.fileAttachments) {
              // Text files are NEVER inlined — regardless of
              // [inlineFileTypes]. We always emit a path-only
              // `<attached_file path="…" />` header so the model
              // can pull the file via the file tool. Inlining
              // decoded text bodies bloats the context window
              // and forces the user to manually pick "text" off
              // every time they configure a model; the path
              // reference is always sufficient.
              final inline =
                  file.textContent == null &&
                  _shouldInline(
                    categorizeFile(name: file.name, mimeType: file.mimeType),
                    inlineFileTypes,
                  );
              if (inline && file.base64Data != null) {
                parts.add({'type': 'text', 'text': _binaryFileHeader(file)});
                parts.add({
                  'type': 'file',
                  'file': {'filename': file.name, 'file_data': file.dataUrl},
                });
              } else {
                // Path-only fallback. Covers:
                //  * text files (always),
                //  * non-text files whose category isn't in
                //    [inlineFileTypes] (user opted out),
                //  * non-text files whose category *is* inline
                //    but the prepared payload has no base64 data
                //    (binary wasn't loaded).
                parts.add({'type': 'text', 'text': _binaryFileHeader(file)});
              }
            }
            for (final url in m.imageDataUrls) {
              // Images go through the same gate — models that
              // don't support images inline get only a path
              // header instead of the base64 data URL.
              final mediaType = _mediaTypeFromDataUrl(url);
              if (_shouldInline(AgentFileType.image, inlineFileTypes)) {
                parts.add({
                  'type': 'image_url',
                  'image_url': {'url': url},
                });
              } else if (mediaType.isNotEmpty) {
                // Emit a tiny header so the model knows the
                // original mime type when it tries to load the
                // path.
                parts.add({
                  'type': 'text',
                  'text':
                      '[Image suppressed: $mediaType — model does '
                      'not accept images inline. The model can read it '
                      'via the file tool from the original path.]',
                });
              }
            }
            out.add({'role': 'user', 'content': parts});
          } else {
            out.add({'role': 'user', 'content': m.content});
          }
          break;
        case MessageRole.assistant:
          if (m.toolCallsWire != null && m.toolCallsWire!.isNotEmpty) {
            // OpenAI requires the assistant message in a tool-calling
            // round-trip to carry the `tool_calls` array verbatim.
            // Content can be null when the model only emitted tool
            // calls.
            out.add({
              'role': 'assistant',
              if (m.content.isNotEmpty) 'content': m.content,
              if (m.content.isEmpty) 'content': null,
              if (m.thinking.isNotEmpty) 'reasoning_content': m.thinking,
              'tool_calls': m.toolCallsWire,
            });
          } else {
            out.add({'role': 'assistant', 'content': m.content});
          }
          break;
        case MessageRole.system:
          out.add({'role': 'system', 'content': m.content});
          break;
        case MessageRole.tool:
          // Tool-result messages go right after the assistant turn
          // that called them. The id comes from `toolCallId`.
          out.add({
            'role': 'tool',
            'tool_call_id': m.toolCallId ?? '',
            'content': m.content,
          });
          break;
      }
    }
    return out;
  }

  List<Map<String, dynamic>> _buildAnthropicMessages(
    List<ChatRequestMessage> messages,
    Set<AgentFileType>? inlineFileTypes, {
    bool promptCacheEnabled = false,
  }) {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final isLastMessage = i == messages.length - 1;
      switch (m.role) {
        case MessageRole.user:
          if (m.imageDataUrls.isNotEmpty || m.fileAttachments.isNotEmpty) {
            final parts = <Map<String, dynamic>>[];
            if (m.content.isNotEmpty) {
              parts.add({'type': 'text', 'text': m.content});
            }
            for (final file in m.fileAttachments) {
              // See the matching comment in [_buildOpenAIMessages]:
              // text files are NEVER inlined, regardless of the
              // configured supported-types set.
              final category = categorizeFile(
                name: file.name,
                mimeType: file.mimeType,
              );
              final isText = file.textContent != null;
              final inline =
                  !isText && _shouldInline(category, inlineFileTypes);
              if (inline &&
                  file.base64Data != null &&
                  file.mimeType.startsWith('image/')) {
                parts.add({'type': 'text', 'text': _binaryFileHeader(file)});
                parts.add({
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': file.mimeType,
                    'data': file.base64Data,
                  },
                });
              } else if (inline && file.base64Data != null) {
                parts.add({'type': 'text', 'text': _binaryFileHeader(file)});
                parts.add({
                  'type': 'document',
                  'source': {
                    'type': 'base64',
                    'media_type': file.mimeType,
                    'data': file.base64Data,
                  },
                  'title': file.name,
                });
              } else {
                // Path-only fallback — see the matching comment
                // in [_buildOpenAIMessages] for the rationale.
                parts.add({'type': 'text', 'text': _binaryFileHeader(file)});
              }
            }
            for (final url in m.imageDataUrls) {
              final mediaType = _mediaTypeFromDataUrl(url);
              final data = _dataFromDataUrl(url);
              if (_shouldInline(AgentFileType.image, inlineFileTypes)) {
                parts.add({
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': mediaType,
                    'data': data,
                  },
                });
              } else if (mediaType.isNotEmpty) {
                parts.add({
                  'type': 'text',
                  'text':
                      '[Image suppressed: $mediaType — model does '
                      'not accept images inline. The model can read it '
                      'via the file tool from the original path.]',
                });
              }
            }
            // Attach the cache breakpoint to the LAST block of
            // the last message only. Per the docs, one marker
            // on the trailing block is sufficient — the server
            // walks back up to 20 blocks to find the longest
            // matching prefix, so we don't need to mark earlier
            // blocks. Marking earlier blocks would just waste
            // one of the 4-breakpoint budget.
            if (promptCacheEnabled && isLastMessage && parts.isNotEmpty) {
              parts.last['cache_control'] = const {'type': 'ephemeral'};
            }
            out.add({'role': 'user', 'content': parts});
          } else {
            // Text-only user turn. Anthropic accepts a flat string
            // for `content`, but to attach `cache_control` we have
            // to convert to a single-block content array. Only do
            // that conversion when caching is on AND this is the
            // last message; otherwise the legacy flat-string wire
            // format is preserved byte-for-byte.
            if (promptCacheEnabled && isLastMessage) {
              out.add({
                'role': 'user',
                'content': [
                  {
                    'type': 'text',
                    'text': m.content,
                    'cache_control': const {'type': 'ephemeral'},
                  },
                ],
              });
            } else {
              out.add({'role': 'user', 'content': m.content});
            }
          }
          break;
        case MessageRole.assistant:
          if (m.anthropicContentBlocks != null &&
              m.anthropicContentBlocks!.isNotEmpty) {
            // Round-trip the assistant content blocks (which include
            // the `tool_use` entries) verbatim. Otherwise the
            // follow-up turn would have no record of what tools the
            // model asked us to call, and the API would 400.
            // NOTE: we deliberately do NOT add `cache_control` to
            // the assistant turn itself — assistant turns are the
            // part that changes the most between rounds, so
            // caching them would mostly invalidate the prefix
            // anyway. The next user message's trailing block is
            // a much better breakpoint.
            out.add({'role': 'assistant', 'content': m.anthropicContentBlocks});
          } else {
            out.add({'role': 'assistant', 'content': m.content});
          }
          break;
        case MessageRole.system:
          // Anthropic uses top-level system; caller should pass via systemPrompts.
          out.add({'role': 'user', 'content': m.content});
          break;
        case MessageRole.tool:
          // Tool-result messages are part of a `user` turn in
          // Anthropic's wire format. They follow the assistant turn
          // that called them. We synthesize a `tool_result` content
          // block keyed by the tool call id.
          out.add({
            'role': 'user',
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': m.toolCallId ?? '',
                'content': m.content,
              },
            ],
          });
          break;
      }
    }
    return out;
  }

  /// Converts OpenAI-style tool schemas (`{type:'function', function:{name,...}}`)
  /// to Anthropic format (`{name, description, input_schema}`).
  ///
  /// When [markLastForCache] is true, attaches `cache_control: {type:
  /// ephemeral}` to the LAST tool only. Per the MiniMax / Anthropic
  /// docs, "you only need a single cache breakpoint at the end of the
  /// static content and the system finds the longest matching prefix"
  /// — so a single marker on the last tool is enough for the tools +
  /// system + earlier-messages prefix to be reused across turns.
  List<Map<String, dynamic>> _toAnthropicTools(
    List<Map<String, dynamic>> openaiTools, {
    bool markLastForCache = false,
  }) {
    final lastIndex = openaiTools.isEmpty ? -1 : openaiTools.length - 1;
    return [
      for (var i = 0; i < openaiTools.length; i++)
        (() {
          final t = openaiTools[i];
          final fn = t['function'] as Map<String, dynamic>?;
          final Map<String, dynamic> out;
          if (fn != null) {
            out = <String, dynamic>{
              'name': fn['name'] ?? '',
              'description': fn['description'] ?? '',
              'input_schema':
                  fn['parameters'] ??
                  {'type': 'object', 'properties': <String, dynamic>{}},
            };
          } else {
            // If the tool is already in Anthropic format (no
            // `function` wrapper), pass it through directly via a
            // shallow copy so we don't mutate the caller's map when
            // we attach cache_control.
            out = Map<String, dynamic>.from(t);
          }
          if (markLastForCache && i == lastIndex) {
            out['cache_control'] = const {'type': 'ephemeral'};
          }
          return out;
        })(),
    ];
  }

  void _applyOpenAIThinking(
    Map<String, dynamic> payload,
    String model,
    bool enabled,
  ) {
    if (!enabled) return;
    final value = model.toLowerCase();
    if (value.contains('qwen')) {
      payload['enable_thinking'] = true;
    } else if (value.contains('doubao') || value.contains('seed')) {
      payload['thinking'] = {'type': 'enabled'};
    } else if (value.startsWith('o1') ||
        value.startsWith('o3') ||
        value.startsWith('o4') ||
        value.contains('gpt-5')) {
      payload['reasoning_effort'] = 'medium';
    }
  }

  @visibleForTesting
  String binaryFileHeaderForTest(PreparedFileAttachment file) =>
      _binaryFileHeader(file);

  /// Self-closing metadata header emitted as a separate text part
  /// right before a binary file payload. Keeps the `name` / `type` /
  /// `path` triple in the same `<attached_file …>` envelope shape
  /// as the previous (now-removed) inline-text envelope so the
  /// model can read the local path for the `file` tool without
  /// parsing the file part. Text files also fall through this
  /// path — they're never inlined.
  String _binaryFileHeader(PreparedFileAttachment file) {
    final attrs = _attachedFileAttrs(file);
    return '<attached_file $attrs />';
  }

  String _attachedFileAttrs(PreparedFileAttachment file) {
    final attrs = StringBuffer()
      ..write('name="${_xmlAttr(file.name)}"')
      ..write(' type="${_xmlAttr(file.mimeType)}"');
    if (file.path.isNotEmpty) {
      attrs.write(' path="${_xmlAttr(file.path)}"');
    }
    return attrs.toString();
  }

  String _xmlAttr(String value) =>
      value.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

  /// Decide whether the wire layer should inline a file's payload
  /// or fall back to a path-only `<attached_file … />` reference.
  ///
  /// Rules:
  ///   * `inlineFileTypes == null` → "legacy / unspecified"
  ///     behaviour: inline everything (matches every test in
  ///     this repo and every provider that pre-dates the
  ///     supported-types UI).
  ///   * `category == null` → the file didn't match any
  ///     well-known category. Don't inline; emit a path header
  ///     only. The model can still pull the bytes via the
  ///     `file` tool.
  ///   * Otherwise → consult the set. `image` decides the
  ///     image_data_url / image-part gating; the other
  ///     categories gate `file_data` / `document` payloads as
  ///     well as the inline-text envelope. Toggling `text` off
  ///     means even the decoded text body is suppressed — the
  ///     user explicitly opted out of having the file contents
  ///     enter the model's context window, so we hand it a path
  ///     header and let the model `file read` it itself.
  bool _shouldInline(AgentFileType? category, Set<AgentFileType>? inline) {
    if (inline == null) return true;
    final c = category;
    if (c == null) return false;
    return inline.contains(c);
  }

  String _mediaTypeFromDataUrl(String dataUrl) {
    final commaIdx = dataUrl.indexOf(',');
    if (dataUrl.startsWith('data:') && commaIdx > 5) {
      final meta = dataUrl.substring(5, commaIdx);
      final semi = meta.indexOf(';');
      if (semi > 0) return meta.substring(0, semi);
    }
    return 'image/jpeg';
  }

  String _dataFromDataUrl(String dataUrl) {
    final commaIdx = dataUrl.indexOf(',');
    if (commaIdx < 0) return dataUrl;
    return dataUrl.substring(commaIdx + 1);
  }
}

class _OpenAIToolCallAccumulator {
  String? id;
  String? name;
  String? arguments;
}
