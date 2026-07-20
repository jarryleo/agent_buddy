import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';
import 'package:uuid/uuid.dart';

import '../models/file_type.dart';
import '../models/local_provider.dart';
import '../models/message.dart';
import 'api_service.dart';
import 'tool_orchestrator.dart';
import 'tool_service.dart';

class GemmaFallbackToolCall {
  const GemmaFallbackToolCall({
    required this.name,
    required this.argumentsRaw,
    required this.arguments,
  });

  final String name;
  final String argumentsRaw;
  final Map<String, dynamic> arguments;
}

class GemmaToolCallFallbackParser {
  static const startToken = '<|tool_call>';
  static const endToken = '<tool_call|>';
  static const invalidToolName = '__invalid_tool_call__';

  final List<GemmaFallbackToolCall> _calls = [];
  String _pending = '';
  bool _closed = false;

  List<GemmaFallbackToolCall> get calls => List.unmodifiable(_calls);

  String feed(String delta) {
    if (_closed) throw StateError('Gemma fallback parser is closed');
    if (delta.isEmpty) return '';
    _pending = '$_pending$delta';
    return _drain(finalChunk: false);
  }

  String close() {
    if (_closed) return '';
    _closed = true;
    return _drain(finalChunk: true);
  }

  String _drain({required bool finalChunk}) {
    final visible = StringBuffer();
    while (_pending.isNotEmpty) {
      final start = _pending.indexOf(startToken);
      if (start == -1) {
        if (finalChunk) {
          visible.write(_pending);
          _pending = '';
          break;
        }
        final heldLength = _partialStartTokenLength(_pending);
        final visibleLength = _pending.length - heldLength;
        if (visibleLength > 0) {
          visible.write(_pending.substring(0, visibleLength));
          _pending = _pending.substring(visibleLength);
        }
        break;
      }

      if (start > 0) {
        visible.write(_pending.substring(0, start));
        _pending = _pending.substring(start);
      }

      final end = _pending.indexOf(endToken, startToken.length);
      if (end == -1) {
        if (finalChunk) {
          final parsed = _parseBlock('$_pending$endToken');
          if (parsed == null) {
            visible.write(_pending);
          } else {
            _calls.add(parsed);
          }
          _pending = '';
        }
        break;
      }

      final blockEnd = end + endToken.length;
      final block = _pending.substring(0, blockEnd);
      final parsed = _parseBlock(block);
      if (parsed == null) {
        visible.write(block);
      } else {
        _calls.add(parsed);
      }
      _pending = _pending.substring(blockEnd);
    }
    return visible.toString();
  }

  static int _partialStartTokenLength(String text) {
    final maxLength = text.length < startToken.length - 1
        ? text.length
        : startToken.length - 1;
    for (var length = maxLength; length > 0; length--) {
      if (text.endsWith(startToken.substring(0, length))) return length;
    }
    return 0;
  }

  static GemmaFallbackToolCall? _parseBlock(String block) {
    if (!block.startsWith(startToken) || !block.endsWith(endToken)) {
      return null;
    }
    final body = block
        .substring(startToken.length, block.length - endToken.length)
        .trim();
    var cursor = 0;
    if (!body.startsWith('call', cursor)) return null;
    cursor += 4;
    while (cursor < body.length && _isWhitespace(body.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= body.length || body.codeUnitAt(cursor) != 0x3A) return null;
    cursor++;
    while (cursor < body.length && _isWhitespace(body.codeUnitAt(cursor))) {
      cursor++;
    }
    final braceStart = body.indexOf('{', cursor);
    if (braceStart == -1) return null;
    final name = body.substring(cursor, braceStart).trim();
    if (name.isEmpty) return null;
    final argumentsRaw = body.substring(braceStart).trim();
    final normalized = argumentsRaw
        .replaceAll(r'<|\"|>', '"')
        .replaceAll('<|"|>', '"')
        .replaceAll('<escape>', '"')
        .replaceAllMapped(
          RegExp(r'(^|[{,])\s*([a-zA-Z_][\w\.-]*)\s*:'),
          (match) => '${match.group(1)}"${match.group(2)}":',
        );
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is! Map) throw const FormatException('expected JSON object');
      final arguments = Map<String, dynamic>.from(decoded);
      return GemmaFallbackToolCall(
        name: name,
        argumentsRaw: jsonEncode(arguments),
        arguments: arguments,
      );
    } catch (e) {
      final arguments = <String, dynamic>{
        'attempted_name': name,
        'raw_arguments': argumentsRaw,
        'parse_error': '$e',
      };
      return GemmaFallbackToolCall(
        name: invalidToolName,
        argumentsRaw: jsonEncode(arguments),
        arguments: arguments,
      );
    }
  }

  static bool _isWhitespace(int codeUnit) {
    return codeUnit == 0x20 ||
        codeUnit == 0x0A ||
        codeUnit == 0x0D ||
        codeUnit == 0x09;
  }
}

class LocalLlmService extends ChangeNotifier {
  LlamaEngine? _engine;
  ChatSession? _session;
  String? _loadedProviderId;
  bool _loading = false;
  Object? _loadError;
  bool _supportsVision = false;
  bool _supportsAudio = false;

  /// Id of the chat session the engine is currently bound to. Used
  /// to skip the reset+seed cycle on follow-up turns of the same
  /// session so llama.cpp's KV cache stays hot.
  Object? _boundSessionId;

  /// Counter for synthesizing unique tool-call ids when llamadart
  /// returns an empty/null id (most local chat templates don't
  /// emit an id field). The UI in `ChatProvider` matches
  /// `toolStart` / `toolDone` events to in-message `ToolCall`
  /// bubbles by id, so a missing id lets a single failure on tool
  /// #3 stamp "failed" onto tool #1 and #2 as well. See the
  /// regression test in `test/local_llm_service_test.dart`.
  int _localToolCallSeq = 0;
  static const _uuid = Uuid();

  bool get isReady => _engine != null && _session != null;
  bool get isLoading => _loading;
  String? get loadedProviderId => _loadedProviderId;
  Object? get loadError => _loadError;
  bool get supportsVision => _supportsVision;
  bool get supportsAudio => _supportsAudio;

  /// Whether the active local engine can surface a reasoning
  /// chunk (Qwen3 / DeepSeek-R1 / GLM-4.5 / MagiStral / etc.).
  /// The native llama.cpp backend has supported `delta.thinking`
  /// since llamadart 0.8.14, so on a working engine this is just
  /// a "is the engine ready" check; the caller still chooses
  /// whether to actually open the thinking block via the
  /// `enableThinking` flag on [streamChat].
  bool get _supportsThinking => _engine != null && _session != null;

  /// Clear the last load error. Call after showing it to the user.
  void clearLoadError() {
    if (_loadError == null) return;
    _loadError = null;
    notifyListeners();
  }

  Future<void> ensureLoaded(LocalProvider provider) async {
    if (_loading) return;
    if (_loadedProviderId == provider.id && isReady) return;
    await _disposeEngine();
    _loading = true;
    _loadError = null;
    notifyListeners();
    try {
      final engine = LlamaEngine(LlamaBackend());
      await engine.loadModel(
        provider.modelPath,
        modelParams: ModelParams(
          contextSize: provider.contextSize,
          gpuLayers: provider.gpuLayers,
          flashAttention: FlashAttention.enabled,
          cacheTypeK: _parseCacheType(provider.cacheTypeK),
          cacheTypeV: _parseCacheType(provider.cacheTypeV),
          // n_batch is the per-step compute buffer size. Leaving it
          // unset lets llamadart default to n_ctx, which is fine for
          // 4K context but blows up RAM/VRAM at 32K+ (logits buffer
          // alone is n_batch × vocab_size × 4). The model's stored
          // [LocalProvider.batchSize] is what the user tuned in
          // Settings; falling back to the safe default keeps old
          // configs from re-introducing the OOM.
          batchSize: provider.batchSize > 0
              ? provider.batchSize
              : LocalProvider.kDefaultBatchSize,
          // Forward the user-supplied chat-template override, if
          // any. Passing `null` lets llamadart fall back to the
          // template embedded in the GGUF metadata (the upstream
          // llama.cpp behavior).
          chatTemplate: _chatTemplateParamFor(provider.chatTemplate),
        ),
      );
      if (provider.mmprojPath != null && provider.mmprojPath!.isNotEmpty) {
        try {
          await engine.loadMultimodalProjector(provider.mmprojPath!);
          _supportsVision = await engine.supportsVision;
          _supportsAudio = await engine.supportsAudio;
        } catch (_) {
          _supportsVision = false;
          _supportsAudio = false;
        }
      } else {
        _supportsVision = false;
        _supportsAudio = false;
      }
      _engine = engine;
      _session = ChatSession(engine);
      _loadedProviderId = provider.id;
    } catch (e) {
      _loadError = e;
      rethrow;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Stream<StreamEvent> streamChat({
    required LocalProvider provider,
    required List<String> systemPrompts,
    required List<ChatRequestMessage> messages,
    required List<Map<String, dynamic>> tools,
    bool enableThinking = false,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
    ToolOrchestrator? orchestrator,

    /// File categories the local model accepts inline (base64
    /// image / decoded text body). Anything outside the set
    /// becomes a path-only `<attached_file … />` reference;
    /// the model can still pull the bytes via the `file` tool
    /// using the path in the header. `null` = inline everything
    /// (legacy behaviour, used by tests).
    Set<AgentFileType>? inlineFileTypes,

    /// Identifier of the chat session this turn belongs to. The
    /// engine's KV cache is only useful across turns of the same
    /// session, so we use this to decide whether to reset+seed the
    /// engine's ChatSession (cache miss) or just continue (cache
    /// hit). Pass null to force a reset on every call (legacy
    /// behavior, useful for tests).
    Object? boundSessionId,
    void Function(Object?)? onBoundSessionId,
  }) async* {
    if (!isReady) {
      try {
        await ensureLoaded(provider);
      } catch (e) {
        yield StreamEvent.error('Failed to load model: $e');
        return;
      }
    }
    final engine = _engine;
    final session = _session;
    if (engine == null || session == null) {
      yield StreamEvent.error('Local model is not loaded');
      return;
    }

    // KV-cache reuse: only reset+seed when the bound session id
    // changes (or is null). Same-session turns keep the engine's
    // KV cache hot, so each new turn only does the prefill for
    // the new user message + decode — not the entire history.
    final joinedPrompt = systemPrompts.isNotEmpty
        ? systemPrompts.join('\n\n')
        : '';
    final sameSession =
        boundSessionId != null &&
        _boundSessionId != null &&
        _boundSessionId == boundSessionId;
    if (!sameSession) {
      session.systemPrompt = joinedPrompt.isEmpty ? null : joinedPrompt;
      session.reset(keepSystemPrompt: true);
      final historyMessages = messages.length > 1
          ? messages.sublist(0, messages.length - 1)
          : <ChatRequestMessage>[];
      _seedHistory(session, historyMessages, inlineFileTypes);
      _boundSessionId = boundSessionId;
      if (onBoundSessionId != null) onBoundSessionId(boundSessionId);
    } else {
      // Same session, follow-up turn: the system prompt may have
      // changed (user switched role mid-conversation). Llama's
      // ChatSession re-applies it as a soft slot, no reset needed.
      session.systemPrompt = joinedPrompt.isEmpty ? null : joinedPrompt;
    }

    final llamaTools = _buildTools(tools);
    final availableToolNames = {for (final tool in llamaTools) tool.name};
    final fallbackEnabled = onToolCall != null && llamaTools.isNotEmpty;

    final parts = _buildUserParts(messages, inlineFileTypes);
    if (parts.isEmpty) {
      yield StreamEvent.error('No user content to send');
      return;
    }

    // We can't `yield` from inside the `runOneTurn` closure passed
    // to the orchestrator (it must return a Stream, not be a
    // generator running inside another generator). The local
    // engine's `session.create` is a Stream<GenerationChunk> that we
    // want to forward live to the chat UI. So: we run a private
    // StreamController; the runOneTurn generator pumps its session
    // chunks into the controller, and the controller's output is
    // what we `yield*` to the caller. The orchestrator's "loop"
    // sits on top.
    final outbound = StreamController<StreamEvent>();
    final completer = Completer<void>();

    // Run the orchestrator on a microtask so the `await for` below
    // is ready to consume the outbound stream before any events are
    // pushed.
    Future<void> orchFuture() async {
      // The local engine owns the conversation history itself; the
      // orchestrator's working history list is just a marker. Each
      // per-round "runOneTurn" advances the session and inspects its
      // history to extract the just-produced tool calls.
      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        final historyBefore = session.history.length;
        final fallbackParser = GemmaToolCallFallbackParser();
        // Empty parts array is the engine's way of saying "continue
        // the conversation". We use it on follow-up rounds after the
        // initial user turn has been added.
        final isFollowup = history.isNotEmpty;
        // Build the optional reasoning-budget. The native llama.cpp
        // backend's reasoning sampler forces the model's </think>
        // tag once the budget is exhausted, so a thinking model
        // doesn't spend the entire context on chain-of-thought and
        // never produce a real answer ("降智" symptom). The chat
        // template's `enable_thinking` flag is what actually opens
        // the block; the budget only matters once it's open. We
        // only attach a budget when the user is *also* asking for
        // thinking — otherwise an enable_thinking=false template
        // would still pay the reasoning-sampler overhead for no
        // reason.
        final thinkingBudget = resolveThinkingBudget(
          provider: provider,
          enableThinking: enableThinking,
          supportsThinking: _supportsThinking,
        );
        try {
          await for (final chunk in session.create(
            isFollowup ? const <LlamaContentPart>[] : parts,
            params: GenerationParams(
              maxTokens: provider.maxTokens,
              temp: provider.temperature,
              thinkingBudget: thinkingBudget,
            ),
            tools: llamaTools.isEmpty ? null : llamaTools,
            toolChoice: llamaTools.isEmpty ? ToolChoice.none : ToolChoice.auto,
            // Previously we AND-ed this with `!_useNativeBackend`,
            // which silently turned off thinking for every native
            // (llama.cpp) install. The native backend has supported
            // reasoning chunks since llamadart 0.8.14, so we now
            // honor the caller's flag directly.
            enableThinking: enableThinking && _supportsThinking,
          )) {
            if (chunk.choices.isEmpty) continue;
            final delta = chunk.choices.first.delta;
            if (delta.thinking != null && delta.thinking!.isNotEmpty) {
              yield OrchestratorEvent.reasoning(delta.thinking!);
            }
            if (delta.content != null && delta.content!.isNotEmpty) {
              final visible = fallbackEnabled
                  ? fallbackParser.feed(delta.content!)
                  : delta.content!;
              if (visible.isNotEmpty) {
                yield OrchestratorEvent.content(visible);
              }
            }
          }
        } catch (e) {
          yield OrchestratorEvent.turnDone(TurnResult(protocolError: '$e'));
          return;
        }

        final trailing = fallbackParser.close();
        if (trailing.isNotEmpty) {
          yield OrchestratorEvent.content(trailing);
        }
        final calls = _lastToolCalls(session, historyBefore);
        final parsedCalls = <ParsedToolCall>[];
        final seenCalls = <String>{};
        for (final call in calls) {
          final id = call['id'] as String? ?? '';
          final name = call['name'] as String? ?? '';
          final argsRaw = call['arguments'] as String? ?? '';
          final argsMap =
              (call['argsMap'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          seenCalls.add('$name\u0000${jsonEncode(argsMap)}');
          parsedCalls.add(
            ParsedToolCall(
              id: id,
              name: name,
              argumentsRaw: argsRaw,
              arguments: argsMap,
            ),
          );
        }
        for (final call in fallbackParser.calls) {
          final signature = '${call.name}\u0000${jsonEncode(call.arguments)}';
          if (!seenCalls.add(signature)) continue;
          parsedCalls.add(
            ParsedToolCall(
              id: resolveToolCallId(null),
              name: call.name,
              argumentsRaw: call.argumentsRaw,
              arguments: call.arguments,
            ),
          );
        }
        yield OrchestratorEvent.turnDone(
          TurnResult(toolCalls: parsedCalls, emittedAnyContent: true),
        );
      }

      try {
        if (onToolCall != null && llamaTools.isNotEmpty) {
          final orch = orchestrator ?? ToolOrchestrator();
          await for (final ev in orch.run(
            runOneTurn: runOneTurn,
            initialHistory: const <ChatRequestMessage>[],
            executor: (call) => executeLocalToolCall(
              call: call,
              availableToolNames: availableToolNames,
              execute: () => onToolCall({
                'id': call.id,
                'name': call.name,
                'arguments': call.arguments,
              }),
              onResult: (result) {
                session.addMessage(
                  LlamaChatMessage.withContent(
                    role: LlamaChatRole.tool,
                    content: [
                      LlamaToolResultContent(
                        id: call.id,
                        name: call.name,
                        result: result,
                      ),
                    ],
                  ),
                );
              },
            ),
            onTurnCommitted: (_) {},
          )) {
            switch (ev.kind) {
              case OrchestratorEventKind.content:
                outbound.add(
                  StreamEvent(type: 'content', contentDelta: ev.contentDelta),
                );
                break;
              case OrchestratorEventKind.reasoning:
                outbound.add(
                  StreamEvent(
                    type: 'reasoning',
                    thinkingDelta: ev.thinkingDelta,
                  ),
                );
                break;
              case OrchestratorEventKind.toolStart:
                outbound.add(
                  StreamEvent.toolStart(
                    id: ev.toolId!,
                    name: ev.toolName!,
                    arguments: ev.toolArguments ?? '',
                  ),
                );
                break;
              case OrchestratorEventKind.toolDone:
                outbound.add(
                  StreamEvent.toolDone(
                    id: ev.toolId!,
                    name: ev.toolName!,
                    result: ev.toolResult ?? '',
                    success: ev.toolSuccess ?? false,
                    error: ev.toolError,
                  ),
                );
                break;
              case OrchestratorEventKind.error:
                outbound.add(StreamEvent(type: 'error', error: ev.error));
                break;
              case OrchestratorEventKind.turnDone:
                // Internal sentinel; never forwarded to the chat UI.
                break;
            }
          }
        } else {
          // Single turn (no orchestrator). Just run one turn and
          // stream the events.
          await for (final ev in runOneTurn(const <ChatRequestMessage>[])) {
            if (ev.kind == OrchestratorEventKind.turnDone) {
              if (ev.turnResult?.protocolError != null) {
                outbound.add(StreamEvent.error(ev.turnResult!.protocolError!));
              }
              continue;
            }
            if (ev.kind == OrchestratorEventKind.content) {
              outbound.add(
                StreamEvent(type: 'content', contentDelta: ev.contentDelta),
              );
            } else if (ev.kind == OrchestratorEventKind.reasoning) {
              outbound.add(
                StreamEvent(type: 'reasoning', thinkingDelta: ev.thinkingDelta),
              );
            }
          }
        }
      } finally {
        await outbound.close();
        if (!completer.isCompleted) completer.complete();
      }
    }

    // Bridge: yield every event the orchestrator pushes into
    // `outbound` to the caller, and resolve `completer` when the
    // stream closes. Note: `outbound.stream` is a single-subscription
    // stream, so we must consume it exactly once — here, via the
    // `await for` loop. Do NOT add a `.listen(...)` to the same
    // stream (that double-listens and throws
    // "Stream has already been listened to").
    unawaited(orchFuture());

    await for (final ev in outbound.stream) {
      yield ev;
    }
    await completer.future;
    yield StreamEvent.done();
  }

  /// Free the loaded model (if any) and drop the engine. The next chat
  /// will trigger a fresh `ensureLoaded`. Safe to call when nothing is
  /// loaded.
  Future<void> releaseModel() async {
    if (_engine == null && _session == null) return;
    await _disposeEngine();
    if (_loadError != null) {
      _loadError = null;
    }
    notifyListeners();
  }

  Future<void> _disposeEngine() async {
    final engine = _engine;
    _engine = null;
    _session = null;
    _loadedProviderId = null;
    _supportsVision = false;
    _supportsAudio = false;
    _boundSessionId = null;
    if (engine != null) {
      try {
        await engine.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    // Best-effort: drop the engine handle synchronously. The underlying
    // LlamaEngine.dispose() is async, but on app shutdown the native side
    // is torn down anyway. We don't await here because ChangeNotifier's
    // dispose is sync.
    _engine = null;
    _session = null;
    _loadedProviderId = null;
    _supportsVision = false;
    _supportsAudio = false;
    _boundSessionId = null;
    super.dispose();
  }

  void _seedHistory(
    ChatSession session,
    List<ChatRequestMessage> messages,
    Set<AgentFileType>? inlineFileTypes,
  ) {
    for (final m in messages) {
      if (m.role == MessageRole.system) {
        session.addMessage(
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: m.content,
          ),
        );
        continue;
      }
      final role = m.role == MessageRole.user
          ? LlamaChatRole.user
          : LlamaChatRole.assistant;
      if (m.role == MessageRole.user &&
          (m.imagePaths.isNotEmpty || m.fileAttachments.isNotEmpty)) {
        final parts = _buildContentParts(m, inlineFileTypes);
        session.addMessage(
          LlamaChatMessage.withContent(role: role, content: parts),
        );
      } else {
        session.addMessage(
          LlamaChatMessage.fromText(role: role, text: m.content),
        );
      }
    }
  }

  List<LlamaContentPart> _buildUserParts(
    List<ChatRequestMessage> messages,
    Set<AgentFileType>? inlineFileTypes,
  ) {
    // We use the last user message as the new turn's content; the
    // history was already seeded above.
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != MessageRole.user) continue;
      if (m.imagePaths.isNotEmpty || m.fileAttachments.isNotEmpty) {
        return _buildContentParts(m, inlineFileTypes);
      }
      return <LlamaContentPart>[LlamaTextContent(m.content)];
    }
    return const <LlamaContentPart>[];
  }

  @visibleForTesting
  List<LlamaContentPart> buildContentPartsForTest(
    ChatRequestMessage message, [
    Set<AgentFileType>? inlineFileTypes,
  ]) => _buildContentParts(message, inlineFileTypes);

  /// Build the multi-part content for a user message with images
  /// and/or file attachments. The [inlineFileTypes] set mirrors the
  /// cloud wire-builder's gate: when a file's category isn't in
  /// the set, we still emit a path header so the model can use the
  /// `file` tool to read it — but we don't inline the binary /
  /// decoded text body. `null` means "inline everything" (legacy
  /// behaviour).
  ///
  /// Text files are NEVER inlined, regardless of the configured
  /// set — the model always gets the path header so it can pull
  /// the file via the `file` tool. This matches the cloud wire
  /// behaviour; the local engine has no separate text slot anyway,
  /// so it would be the same header either way.
  List<LlamaContentPart> _buildContentParts(
    ChatRequestMessage message,
    Set<AgentFileType>? inlineFileTypes,
  ) {
    final text = StringBuffer(message.content);
    final fileImages = <String>[];
    final inlineImages = _shouldInline(AgentFileType.image, inlineFileTypes);
    for (final file in message.fileAttachments) {
      final category = categorizeFile(name: file.name, mimeType: file.mimeType);
      // Text files are always path-only — see the doc above.
      // Non-text files respect the inline gate.
      final isText = file.textContent != null;
      final inline = !isText && _shouldInline(category, inlineFileTypes);
      if (inline &&
          file.mimeType.startsWith('image/') &&
          file.path.isNotEmpty) {
        fileImages.add(file.path);
      } else {
        // Path-only: covers text files (always), non-text
        // binaries when the category isn't in the set, and any
        // unknown case. The local engine doesn't have a separate
        // file_data slot, so even "inline" non-image binaries
        // collapse to the same path header.
        if (text.isNotEmpty) text.write('\n\n');
        text.write(
          '[Attached file: ${file.name}, type=${file.mimeType}, path=${file.path}]',
        );
      }
    }
    return <LlamaContentPart>[
      if (text.isNotEmpty) LlamaTextContent(text.toString()),
      if (inlineImages)
        for (final path in message.imagePaths) LlamaImageContent(path: path),
      if (inlineImages)
        for (final path in fileImages) LlamaImageContent(path: path),
    ];
  }

  /// Mirror of [ApiService._shouldInline]. Duplicated here so the
  /// local LLM service doesn't have to pull in the cloud wire
  /// builder just to ask "should I inline this?". See the matching
  /// comment in `api_service.dart` for the full rule table.
  bool _shouldInline(AgentFileType? category, Set<AgentFileType>? inline) {
    if (inline == null) return true;
    final c = category;
    if (c == null) return false;
    return inline.contains(c);
  }

  List<Map<String, dynamic>> _lastToolCalls(
    ChatSession session,
    int historyBefore,
  ) {
    final out = <Map<String, dynamic>>[];
    for (var i = historyBefore; i < session.history.length; i++) {
      final msg = session.history[i];
      if (msg.role != LlamaChatRole.assistant) continue;
      for (final part in msg.parts) {
        if (part is LlamaToolCallContent) {
          // Always mint a fresh id for the local-LLM path, even
          // when llamadart already gave us a non-empty one.
          // Rationale:
          //   1. Many local chat templates don't emit an id at
          //      all — llamadart hands us `null` or `''`. If we
          //      passed that through, every tool call in a turn
          //      would share the same empty id, and the chat
          //      provider's toolDone handler would stamp a single
          //      failure onto all of them (regression: a 404 on
          //      the last tool call painted "failed 404" onto
          //      every previous tool call in the same turn).
          //   2. The templates that *do* emit an id (Hermes
          //      handler in llamadart 0.8.14 uses
          //      `call_$toolCalls.length`, other handlers have
          //      similar index-based schemes) can still collide
          //      when the model itself emits a literal
          //      `{"id": "call_0", ...}` for every tool call —
          //      which is exactly what Hermes-style models do.
          //      Two sibling tool calls in the same assistant
          //      turn then both arrive as `id: "call_0"`, and
          //      Flutter's `ValueKey('tool_call_0')` collides in
          //      the MessageBubble Column.
          //   3. The id is opaque to llama.cpp — it just round-
          //      trips through `LlamaToolResultContent.id` and
          //      the engine tracks tool calls by their position
          //      in the conversation, not by id. So synthesizing
          //      locally is safe.
          out.add({
            'id': resolveToolCallId(part.id),
            'name': part.name,
            'arguments': part.rawJson,
            'argsMap': part.arguments,
          });
        }
      }
    }
    return out;
  }

  @visibleForTesting
  static Future<String> executeLocalToolCall({
    required ParsedToolCall call,
    required Set<String> availableToolNames,
    required Future<String> Function() execute,
    required void Function(String result) onResult,
  }) async {
    if (!availableToolNames.contains(call.name)) {
      final error = call.name == GemmaToolCallFallbackParser.invalidToolName
          ? 'invalid Gemma tool call arguments for "${call.arguments['attempted_name'] ?? ''}"; retry with a valid JSON object'
          : 'unknown or unavailable tool: ${call.name}; use an exact available function name: ${(availableToolNames.toList()..sort()).join(', ')}';
      onResult('Error: $error');
      throw ToolException(error);
    }
    try {
      final result = await execute();
      onResult(result);
      return result;
    } catch (e) {
      onResult('Error: $e');
      rethrow;
    }
  }

  /// Returns a non-empty, unique id for a tool call produced by
  /// the local model. Always synthesizes a fresh id, even when
  /// llamadart already supplied a non-empty one. The raw id is
  /// unreliable for two reasons:
  ///   1. Most local chat templates don't emit a tool-call id
  ///      at all (the value comes back as `null` or `''`).
  ///   2. Templates that *do* emit an id (Hermes, functionary,
  ///      …) typically use a per-turn `call_$index` scheme, and
  ///      the model itself can also emit a literal
  ///      `{"id": "call_0", ...}` for every tool call — so
  ///      sibling tool calls in the same assistant turn can
  ///      collide on the same id (e.g. two `call_0`s), which
  ///      blows up the `ValueKey('tool_${tc.id}')` in
  ///      `MessageBubble._buildToolCalls`.
  /// The synthesized id is opaque to llama.cpp — the engine
  /// tracks tool calls by their position in the conversation,
  /// not by id, so generating one locally is safe.
  @visibleForTesting
  String resolveToolCallId(String? rawId) {
    return 'local-${_localToolCallSeq++}-${_uuid.v4()}';
  }

  static KvCacheType _parseCacheType(String raw) {
    switch (raw) {
      case 'q8_0':
        return KvCacheType.q8_0;
      case 'q4_0':
        return KvCacheType.q4_0;
      case 'f16':
      default:
        return KvCacheType.f16;
    }
  }

  /// Coerce the user-supplied chat-template override into the shape
  /// `ModelParams.chatTemplate` expects.
  ///
  /// `null` / whitespace-only → `null` (let llamadart fall back to
  /// the template embedded in the GGUF). Whitespace around a
  /// non-empty template is preserved (Jinja is whitespace-
  /// sensitive near delimiters), but we still strip the leading /
  /// trailing newlines that the bundled `.jinja` assets end with
  /// so the user sees the same payload they'd see in an upstream
  /// PR — a trailing `\n` would otherwise show up as an empty
  /// last line in the textarea.
  static String? _chatTemplateParamFor(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  /// Resolves the [ThinkingBudget] to attach to the engine's
  /// [GenerationParams] for a given turn. Returns `null` when the
  /// reasoning sampler should not be active for this turn — which
  /// covers four orthogonal cases:
  ///
  /// 1. `enableThinking` is `false` (user toggled thinking off in
  ///    chat settings, or the active chat role does not request
  ///    it). The budget would never be hit anyway because the
  ///    chat template wouldn't open the block, but skipping it
  ///    saves the reasoning-sampler overhead.
  /// 2. The engine is not ready (`supportsThinking == false`).
  ///    Defensive: would only happen if the caller asked for
  ///    thinking before the model finished loading.
  /// 3. The provider's budget is `null` ("no cap" — the user
  ///    explicitly chose the leftmost tick on the slider).
  /// 4. The provider's budget is `0` (sentinel for the same
  ///    thing, e.g. on a row migrated from an older config).
  ///
  /// Exposed at top level (static) so the rules are unit-testable
  /// without spinning up an engine.
  @visibleForTesting
  static ThinkingBudget? resolveThinkingBudget({
    required LocalProvider provider,
    required bool enableThinking,
    required bool supportsThinking,
  }) {
    if (!enableThinking) return null;
    if (!supportsThinking) return null;
    final tokens = provider.thinkingBudgetTokens;
    if (tokens == null || tokens <= 0) return null;
    return ThinkingBudget(maxTokens: tokens);
  }

  List<ToolDefinition> _buildTools(List<Map<String, dynamic>> openAiTools) {
    if (openAiTools.isEmpty) return const [];
    final out = <ToolDefinition>[];
    for (final raw in openAiTools) {
      final fn = (raw['function'] as Map?)?.cast<String, dynamic>();
      if (fn == null) continue;
      final name = fn['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final description = fn['description'] as String? ?? '';
      final paramsRaw =
          (fn['parameters'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final props =
          (paramsRaw['properties'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final required =
          (paramsRaw['required'] as List?)?.cast<String>() ?? const <String>[];
      final parameters = <ToolParam>[];
      props.forEach((pname, pdef) {
        final def = (pdef as Map?)?.cast<String, dynamic>() ?? const {};
        final type = def['type'] as String? ?? 'string';
        final desc = def['description'] as String?;
        final isRequired = required.contains(pname);
        switch (type) {
          case 'integer':
          case 'number':
            parameters.add(
              ToolParam.number(pname, description: desc, required: isRequired),
            );
            break;
          case 'boolean':
            parameters.add(
              ToolParam.boolean(pname, description: desc, required: isRequired),
            );
            break;
          default:
            parameters.add(
              ToolParam.string(pname, description: desc, required: isRequired),
            );
        }
      });
      out.add(
        ToolDefinition(
          name: name,
          description: description,
          parameters: parameters,
          // The handler is unused because we execute tools ourselves
          // after parsing the assistant message. Returning an empty
          // string keeps llamadart happy if it ever does invoke it.
          handler: (params) async => '',
        ),
      );
    }
    return out;
  }
}
