import 'dart:async';
import 'dart:io';

import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/download_service.dart';
import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/notification_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_retry_it_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<ChatProvider> buildProvider({
    required StorageService storage,
    required bool failWithClientException,
  }) async {
    final settings = SettingsProvider(storage);
    await settings.load();

    // Register a cloud (OpenAI-compatible) provider + model and make
    // it active. Disable local model so we take the cloud+retry path.
    final created = await settings.addProvider(
      name: 'OpenRouter',
      protocol: ProviderProtocol.openai,
      baseUrl: 'https://openrouter.ai/api/v1',
      apiKey: 'test-key',
      chatPath: '/chat/completions',
    );
    final withModel = created.copyWith(
      models: ['openai/gpt-4o-mini'],
      selectedModel: 'openai/gpt-4o-mini',
    );
    await settings.updateProvider(withModel);
    await settings.setActiveProvider(withModel.id);
    await settings.setUseLocalModel(false);

    final api = ApiService(
      client: MockClient((request) async {
        if (failWithClientException) {
          throw http.ClientException(
            'Connection closed before full header was received',
            request.url,
          );
        }
        return http.Response('{"choices":[]}', 200);
      }),
    );

    final tools = ToolService(storage: storage);
    final chat = ChatProvider(
      storage,
      api,
      tools,
      ImageService(),
      LocalLlmService(),
      settings,
      DownloadService(),
      FileAttachmentService(),
    );
    return chat;
  }

  testWidgets('a ClientException from the cloud provider triggers the retry '
      'loop instead of a hard error', (tester) async {
    final storage = StorageService();
    await storage.init();
    final chat = await buildProvider(
      storage: storage,
      failWithClientException: true,
    );

    // Drive sendMessage without awaiting (it loops forever on
    // retryable errors). We just need to observe the in-flight
    // state flip to "retrying".
    final ctx = tester.element(find.byType(Container));
    unawaited(chat.sendMessage(ctx, 'hello'));

    // Give the first attempt + error classification a tick.
    await tester.pump(const Duration(milliseconds: 500));

    final assistant = storage.sessions
        .get(chat.activeSessionId)
        ?.messages
        .where((m) => m.role == MessageRole.assistant)
        .lastOrNull;
    expect(assistant, isNotNull, reason: 'assistant bubble exists');
    expect(
      assistant!.isRetrying,
      isTrue,
      reason: 'bubble should be in retry state, not a hard error',
    );
    expect(
      assistant.content,
      isNot(contains('出错了')),
      reason: 'should NOT show the hard-error prefix',
    );

    // Clean up so the lingering retry wait does not bleed into
    // other tests.
    chat.stopGeneration();
  });
}
