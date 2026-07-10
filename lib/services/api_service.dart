import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/message.dart';
import '../models/provider.dart';
import 'tool_orchestrator.dart';

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
  });

  factory StreamEvent.error(String msg) =>
      StreamEvent(type: 'error', error: msg);
  factory StreamEvent.done() => const StreamEvent(type: 'done', done: true);
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
    this.toolCallId,
    this.toolName,
    this.toolCallsWire,
    this.anthropicContentBlocks,
  });
}

class ApiService {
  final http.Client _client = http.Client();

  void dispose() {
    _client.close();
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
  Stream<StreamEvent> streamChat({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
    ToolOrchestrator? orchestrator,
  }) async* {
    // Without an executor there's no point in the orchestrator — the
    // model can't actually call any tools, so we just do a single
    // turn.
    if (onToolCall == null) {
      yield* _streamSingleTurn(
        provider: provider,
        model: model,
        messages: messages,
        systemPrompt: systemPrompt,
        tools: tools,
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
    Stream<OrchestratorEvent> runOneTurn(List<ChatRequestMessage> h) {
      switch (provider.protocol) {
        case ProviderProtocol.openai:
          return _runOpenAITurn(
            provider: provider,
            model: model,
            history: h,
            systemPrompt: systemPrompt,
            tools: tools,
          );
        case ProviderProtocol.anthropic:
          return _runAnthropicTurn(
            provider: provider,
            model: model,
            history: h,
            systemPrompt: systemPrompt,
            tools: tools,
          );
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
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
  }) async* {
    switch (provider.protocol) {
      case ProviderProtocol.openai:
        yield* _streamOpenAISingleTurn(
          provider: provider,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          tools: tools,
        );
        break;
      case ProviderProtocol.anthropic:
        yield* _streamAnthropicSingleTurn(
          provider: provider,
          model: model,
          messages: messages,
          systemPrompt: systemPrompt,
          tools: tools,
        );
        break;
    }
  }

  Stream<StreamEvent> _streamOpenAISingleTurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> messages,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
  }) async* {
    // Backward-compat wrapper: run a single turn, ignore any tool
    // calls the model emits, just stream the text. (No orchestrator
    // involved.)
    TurnResult? finalResult;
    await for (final ev in _runOpenAITurn(
      provider: provider,
      model: model,
      history: messages,
      systemPrompt: systemPrompt,
      tools: tools,
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
    required String? systemPrompt,
    required List<Map<String, dynamic>>? tools,
  }) async* {
    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'messages': _buildOpenAIMessages(history, systemPrompt),
    };
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
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
  }) async* {
    // Backward-compat wrapper: run a single turn, ignore any tool
    // calls the model emits, just stream the text. (No orchestrator
    // involved.)
    TurnResult? finalResult;
    await for (final ev in _runAnthropicTurn(
      provider: provider,
      model: model,
      history: messages,
      systemPrompt: systemPrompt,
      tools: tools,
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

  /// Runs a single Anthropic turn. Streams live deltas as
  /// `OrchestratorEvent`s and ends with a `OrchestratorEvent.turnDone`
  /// carrying the parsed [TurnResult].
  Stream<OrchestratorEvent> _runAnthropicTurn({
    required ModelProvider provider,
    required String model,
    required List<ChatRequestMessage> history,
    required String? systemPrompt,
    required List<Map<String, dynamic>>? tools,
  }) async* {
    final payload = <String, dynamic>{
      'model': model,
      'stream': true,
      'max_tokens': 4096,
      'messages': _buildAnthropicMessages(history),
    };
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      payload['system'] = systemPrompt;
    }
    if (tools != null && tools.isNotEmpty) {
      payload['tools'] = tools;
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
      if (data.isEmpty) continue;
      try {
        final json = jsonDecode(data) as Map<String, dynamic>;
        final type = json['type'] as String?;
        switch (type) {
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
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta != null && delta['stop_reason'] is String) {
              currentStopReason = delta['stop_reason'] as String;
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

    final hasBlocks = contentBlocks.isNotEmpty;
    if (currentContent.isNotEmpty) {
      contentBlocks.insert(0, {'type': 'text', 'text': currentContent});
    }
    if (currentReasoning.isNotEmpty) {
      // Anthropic puts thinking into its own `thinking` content
      // block, but for the purposes of feeding back to the model we
      // treat it as a text block. The reasoning has already been
      // streamed to the UI via `emitReasoning`; the assistant
      // content blocks we serialize here are only for the wire
      // payload.
      contentBlocks.insert(0, {'type': 'text', 'text': currentReasoning});
    }

    final assistantTurn = ChatRequestMessage(
      role: MessageRole.assistant,
      content: currentContent,
      thinking: currentReasoning,
      anthropicContentBlocks: hasBlocks || currentContent.isNotEmpty
          ? contentBlocks
          : null,
    );

    if (currentStopReason == 'refusal') {
      yield OrchestratorEvent.turnDone(
        TurnResult(
          assistantTurn: assistantTurn,
          protocolError: 'Response was refused by the API',
          emittedAnyContent: anyContent,
        ),
      );
      return;
    }

    yield OrchestratorEvent.turnDone(
      TurnResult(
        assistantTurn: assistantTurn,
        toolCalls: parsedCalls,
        truncated: currentStopReason == 'max_tokens',
        emittedAnyContent: anyContent,
      ),
    );
  }

  List<Map<String, dynamic>> _buildOpenAIMessages(
    List<ChatRequestMessage> messages,
    String? systemPrompt,
  ) {
    final out = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      out.add({'role': 'system', 'content': systemPrompt});
    }
    for (final m in messages) {
      switch (m.role) {
        case MessageRole.user:
          if (m.imageDataUrls.isNotEmpty) {
            final parts = <Map<String, dynamic>>[];
            if (m.content.isNotEmpty) {
              parts.add({'type': 'text', 'text': m.content});
            }
            for (final url in m.imageDataUrls) {
              parts.add({
                'type': 'image_url',
                'image_url': {'url': url},
              });
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
  ) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      switch (m.role) {
        case MessageRole.user:
          if (m.imageDataUrls.isNotEmpty) {
            final parts = <Map<String, dynamic>>[];
            if (m.content.isNotEmpty) {
              parts.add({'type': 'text', 'text': m.content});
            }
            for (final url in m.imageDataUrls) {
              // OpenAI-style data URLs (`data:image/...;base64,...`)
              // round-trip into Anthropic's expected source object.
              final mediaType = _mediaTypeFromDataUrl(url);
              final data = _dataFromDataUrl(url);
              parts.add({
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': mediaType,
                  'data': data,
                },
              });
            }
            out.add({'role': 'user', 'content': parts});
          } else {
            out.add({'role': 'user', 'content': m.content});
          }
          break;
        case MessageRole.assistant:
          if (m.anthropicContentBlocks != null &&
              m.anthropicContentBlocks!.isNotEmpty) {
            // Round-trip the assistant content blocks (which include
            // the `tool_use` entries) verbatim. Otherwise the
            // follow-up turn would have no record of what tools the
            // model asked us to call, and the API would 400.
            out.add({'role': 'assistant', 'content': m.anthropicContentBlocks});
          } else {
            out.add({'role': 'assistant', 'content': m.content});
          }
          break;
        case MessageRole.system:
          // Anthropic uses top-level system; caller should pass via systemPrompt.
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
