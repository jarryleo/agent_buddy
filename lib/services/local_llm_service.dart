import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../models/local_provider.dart';
import '../models/message.dart';
import 'api_service.dart';
import 'tool_orchestrator.dart';

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

  bool get isReady => _engine != null && _session != null;
  bool get isLoading => _loading;
  String? get loadedProviderId => _loadedProviderId;
  Object? get loadError => _loadError;
  bool get supportsVision => _supportsVision;
  bool get supportsAudio => _supportsAudio;

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
          flashAttention: FlashAttention.enabled
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
    required String systemPrompt,
    required List<ChatRequestMessage> messages,
    required List<Map<String, dynamic>> tools,
    Future<String> Function(Map<String, dynamic> toolCall)? onToolCall,
    ToolOrchestrator? orchestrator,
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
    final sameSession = boundSessionId != null &&
        _boundSessionId != null &&
        _boundSessionId == boundSessionId;
    if (!sameSession) {
      session.systemPrompt = systemPrompt.isEmpty ? null : systemPrompt;
      session.reset(keepSystemPrompt: true);
      final historyMessages = messages.length > 1
          ? messages.sublist(0, messages.length - 1)
          : <ChatRequestMessage>[];
      _seedHistory(session, historyMessages);
      _boundSessionId = boundSessionId;
      if (onBoundSessionId != null) onBoundSessionId(boundSessionId);
    } else {
      // Same session, follow-up turn: the system prompt may have
      // changed (user switched role mid-conversation). Llama's
      // ChatSession re-applies it as a soft slot, no reset needed.
      session.systemPrompt = systemPrompt.isEmpty ? null : systemPrompt;
    }

    final llamaTools = _buildTools(tools);

    final parts = _buildUserParts(messages);
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
    StreamSubscription<StreamEvent>? outboundSub;
    final completer = Completer<void>();

    // Run the orchestrator on a microtask so we can set up the
    // outbound subscription first (no race on the first events).
    Future<void> orchFuture() async {
      // The local engine owns the conversation history itself; the
      // orchestrator's working history list is just a marker. Each
      // per-round "runOneTurn" advances the session and inspects its
      // history to extract the just-produced tool calls.
      Stream<OrchestratorEvent> runOneTurn(
        List<ChatRequestMessage> history,
      ) async* {
        final historyBefore = session.history.length;
        // Empty parts array is the engine's way of saying "continue
        // the conversation". We use it on follow-up rounds after the
        // initial user turn has been added.
        final isFollowup = history.isNotEmpty;
        try {
          await for (final chunk in session.create(
            isFollowup ? const <LlamaContentPart>[] : parts,
            params: GenerationParams(
              maxTokens: provider.maxTokens,
              temp: provider.temperature,
            ),
            tools: llamaTools.isEmpty ? null : llamaTools,
            toolChoice: llamaTools.isEmpty
                ? ToolChoice.none
                : ToolChoice.auto,
          )) {
            if (chunk.choices.isEmpty) continue;
            final delta = chunk.choices.first.delta;
            if (delta.thinking != null && delta.thinking!.isNotEmpty) {
              yield OrchestratorEvent.reasoning(delta.thinking!);
            }
            if (delta.content != null && delta.content!.isNotEmpty) {
              yield OrchestratorEvent.content(delta.content!);
            }
          }
        } catch (e) {
          yield OrchestratorEvent.turnDone(
            TurnResult(protocolError: '$e'),
          );
          return;
        }

        final calls = _lastToolCalls(session, historyBefore);
        final parsedCalls = <ParsedToolCall>[];
        for (final call in calls) {
          final id = call['id'] as String? ?? '';
          final name = call['name'] as String? ?? '';
          final argsRaw = call['arguments'] as String? ?? '';
          final argsMap =
              (call['argsMap'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{};
          parsedCalls.add(
            ParsedToolCall(
              id: id,
              name: name,
              argumentsRaw: argsRaw,
              arguments: argsMap,
            ),
          );
        }
        yield OrchestratorEvent.turnDone(
          TurnResult(
            toolCalls: parsedCalls,
            emittedAnyContent: true,
          ),
        );
      }

      try {
        if (onToolCall != null && llamaTools.isNotEmpty) {
          final orch = orchestrator ?? ToolOrchestrator();
          await for (final ev in orch.run(
            runOneTurn: runOneTurn,
            initialHistory: const <ChatRequestMessage>[],
            executor: (call) async {
              final result = await onToolCall({
                'id': call.id,
                'name': call.name,
                'arguments': call.arguments,
              });
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
              return result;
            },
            onTurnCommitted: (_) {},
          )) {
            switch (ev.kind) {
              case OrchestratorEventKind.content:
                outbound.add(
                  StreamEvent(
                    type: 'content',
                    contentDelta: ev.contentDelta,
                  ),
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
                outbound.add(
                  StreamEvent(type: 'error', error: ev.error),
                );
                break;
              case OrchestratorEventKind.turnDone:
                // Internal sentinel; never forwarded to the chat UI.
                break;
            }
          }
        } else {
          // Single turn (no orchestrator). Just run one turn and
          // stream the events.
          await for (final ev in runOneTurn(
            const <ChatRequestMessage>[],
          )) {
            if (ev.kind == OrchestratorEventKind.turnDone) {
              if (ev.turnResult?.protocolError != null) {
                outbound.add(
                  StreamEvent.error(ev.turnResult!.protocolError!),
                );
              }
              continue;
            }
            if (ev.kind == OrchestratorEventKind.content) {
              outbound.add(
                StreamEvent(
                  type: 'content',
                  contentDelta: ev.contentDelta,
                ),
              );
            } else if (ev.kind == OrchestratorEventKind.reasoning) {
              outbound.add(
                StreamEvent(
                  type: 'reasoning',
                  thinkingDelta: ev.thinkingDelta,
                ),
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
    // stream closes.
    outboundSub = outbound.stream.listen(
      (e) {},
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    // Fire and forget — orchFuture() drains outbound on its own.
    unawaited(orchFuture());

    await for (final ev in outbound.stream) {
      yield ev;
    }
    await completer.future;
    await outboundSub.cancel();
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

  void _seedHistory(ChatSession session, List<ChatRequestMessage> messages) {
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
      if (m.role == MessageRole.user && m.imagePaths.isNotEmpty) {
        final parts = <LlamaContentPart>[
          if (m.content.isNotEmpty) LlamaTextContent(m.content),
          for (final p in m.imagePaths) LlamaImageContent(path: p),
        ];
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

  List<LlamaContentPart> _buildUserParts(List<ChatRequestMessage> messages) {
    // We use the last user message as the new turn's content; the
    // history was already seeded above.
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != MessageRole.user) continue;
      if (m.imagePaths.isNotEmpty) {
        return <LlamaContentPart>[
          if (m.content.isNotEmpty) LlamaTextContent(m.content),
          for (final p in m.imagePaths) LlamaImageContent(path: p),
        ];
      }
      return <LlamaContentPart>[LlamaTextContent(m.content)];
    }
    return const <LlamaContentPart>[];
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
          out.add({
            'id': part.id,
            'name': part.name,
            'arguments': part.rawJson,
            'argsMap': part.arguments,
          });
        }
      }
    }
    return out;
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
