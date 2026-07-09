import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import '../models/local_provider.dart';
import '../models/message.dart';
import 'api_service.dart';

class LocalLlmService extends ChangeNotifier {
  LlamaEngine? _engine;
  ChatSession? _session;
  String? _loadedProviderId;
  bool _loading = false;
  Object? _loadError;
  bool _supportsVision = false;
  bool _supportsAudio = false;

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

    // Set the system prompt and seed history from the incoming message
    // list. ChatSession manages context trimming, so we mirror the
    // existing conversation into its history before adding the new turn.
    session.systemPrompt = systemPrompt.isEmpty ? null : systemPrompt;
    session.reset(keepSystemPrompt: true);
    // Seed history with everything except the last user turn (which
    // ChatSession will add itself when we call create() below).
    final historyMessages = messages.length > 1
        ? messages.sublist(0, messages.length - 1)
        : <ChatRequestMessage>[];
    _seedHistory(session, historyMessages);

    final llamaTools = _buildTools(tools);
    final historyBefore = session.history.length;

    final parts = _buildUserParts(messages);
    if (parts.isEmpty) {
      yield StreamEvent.error('No user content to send');
      return;
    }

    try {
      await for (final chunk in session.create(
        parts,
        params: GenerationParams(
          maxTokens: provider.maxTokens,
          temp: provider.temperature,
        ),
        tools: llamaTools.isEmpty ? null : llamaTools,
        toolChoice: llamaTools.isEmpty ? ToolChoice.none : ToolChoice.auto,
      )) {
        if (chunk.choices.isEmpty) continue;
        final delta = chunk.choices.first.delta;
        if (delta.thinking != null && delta.thinking!.isNotEmpty) {
          yield StreamEvent(type: 'reasoning', thinkingDelta: delta.thinking);
        }
        if (delta.content != null && delta.content!.isNotEmpty) {
          yield StreamEvent(type: 'content', contentDelta: delta.content);
        }
      }
    } catch (e) {
      yield StreamEvent.error('$e');
      return;
    }

    if (onToolCall != null && llamaTools.isNotEmpty) {
      // Inspect the assistant message the session just added; if it
      // carries tool calls, execute them, feed the result back, and
      // stream a follow-up turn.
      final toolCalls = _lastToolCalls(session, historyBefore);
      if (toolCalls.isNotEmpty) {
        for (final call in toolCalls) {
          final id = call['id'] as String? ?? '';
          final name = call['name'] as String? ?? '';
          final argsRaw = call['arguments'] as String? ?? '';
          final argsMap =
              call['argsMap'] as Map<String, dynamic>? ??
              const <String, dynamic>{};
          yield StreamEvent.toolStart(id: id, name: name, arguments: argsRaw);
          String toolResult;
          bool success = true;
          String? toolError;
          try {
            toolResult = await onToolCall({
              'id': id,
              'name': name,
              'arguments': argsMap,
            });
          } catch (e) {
            toolResult = 'Error: $e';
            success = false;
            toolError = e.toString();
          }
          yield StreamEvent.toolDone(
            id: id,
            name: name,
            result: toolResult,
            success: success,
            error: toolError,
          );
          session.addMessage(
            LlamaChatMessage.withContent(
              role: LlamaChatRole.tool,
              content: [
                LlamaToolResultContent(id: id, name: name, result: toolResult),
              ],
            ),
          );
        }
        try {
          await for (final chunk in session.create(
            const <LlamaContentPart>[],
            params: GenerationParams(
              maxTokens: provider.maxTokens,
              temp: provider.temperature,
            ),
            tools: llamaTools,
            toolChoice: ToolChoice.auto,
          )) {
            if (chunk.choices.isEmpty) continue;
            final delta = chunk.choices.first.delta;
            if (delta.thinking != null && delta.thinking!.isNotEmpty) {
              yield StreamEvent(
                type: 'reasoning',
                thinkingDelta: delta.thinking,
              );
            }
            if (delta.content != null && delta.content!.isNotEmpty) {
              yield StreamEvent(type: 'content', contentDelta: delta.content);
            }
          }
        } catch (e) {
          yield StreamEvent.error('$e');
          return;
        }
      }
    }

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
