import 'dart:io';

import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/download_service.dart';
import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for `ChatProvider.isUserInteracting` + the
/// `notifyUserInteracted` affordance that the desktop pet
/// director listens for so it can pause its AI-orchestrated
/// timeline (and cancel any in-flight move) the moment the
/// user touches the chat input.
void main() {
  late Directory tempDir;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_interacting_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<ChatProvider> buildProvider(StorageService storage) async {
    final settings = SettingsProvider(storage);
    await settings.load();
    final created = await settings.addProvider(
      name: 'Test',
      protocol: ProviderProtocol.openai,
      baseUrl: 'https://example.com',
      apiKey: 'test-key',
      chatPath: '/chat/completions',
    );
    final withModel = created.copyWith(
      models: ['gpt-test'],
      selectedModel: 'gpt-test',
    );
    await settings.updateProvider(withModel);
    await settings.setActiveProvider(withModel.id);
    await settings.setUseLocalModel(false);
    final api = ApiService();
    final tools = ToolService(storage: storage);
    return ChatProvider(
      storage,
      api,
      tools,
      ImageService(),
      LocalLlmService(),
      settings,
      DownloadService(),
      FileAttachmentService(),
    );
  }

  setUp(() {
    // Shorten the interaction window so the falling-edge
    // timer fires inside the unit test instead of after
    // 30 real seconds. Restored to the production 30s
    // window at the bottom of `tearDown`.
    ChatProvider.userInteractionWindowForTest = const Duration(
      milliseconds: 50,
    );
  });

  tearDown(() {
    ChatProvider.userInteractionWindowForTest = null;
  });

  test('isUserInteracting starts false on a fresh provider', () async {
    final storage = StorageService();
    await storage.init();
    final provider = await buildProvider(storage);
    expect(provider.isUserInteracting, isFalse);
  });

  test(
    'a single notifyUserInteracted flips the flag and notifies once',
    () async {
      final storage = StorageService();
      await storage.init();
      final provider = await buildProvider(storage);
      var notifications = 0;
      provider.addListener(() => notifications++);
      provider.notifyUserInteracted();
      expect(provider.isUserInteracting, isTrue);
      expect(notifications, 1);
      provider.dispose();
    },
  );

  test('re-arming inside the window does not refire listeners', () async {
    final storage = StorageService();
    await storage.init();
    final provider = await buildProvider(storage);
    provider.notifyUserInteracted();
    var notifications = 0;
    provider.addListener(() => notifications++);
    provider.notifyUserInteracted();
    provider.notifyUserInteracted();
    expect(
      notifications,
      0,
      reason:
          'a flurry of typing while already in the active window '
          'should not flood listeners — the rising-edge already fired.',
    );
    provider.dispose();
  });

  test(
    'the flag clears + a notification fires after the window expires',
    () async {
      final storage = StorageService();
      await storage.init();
      final provider = await buildProvider(storage);
      provider.notifyUserInteracted();
      expect(provider.isUserInteracting, isTrue);

      var fallNotificationCount = 0;
      provider.addListener(() => fallNotificationCount++);

      // Wait for the 50ms fallback timer (the test seam)
      // to fire.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(provider.isUserInteracting, isFalse);
      expect(fallNotificationCount, greaterThanOrEqualTo(1));
      provider.dispose();
    },
  );

  test('re-engaging before the timer fires keeps the flag alive', () async {
    final storage = StorageService();
    await storage.init();
    final provider = await buildProvider(storage);
    provider.notifyUserInteracted();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // Re-arm after 30ms; if the timer re-armed, the flag
    // should still be true at t=70ms (the original 50ms
    // window has elapsed, but the second 50ms window from
    // t=30ms is still in flight).
    provider.notifyUserInteracted();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      provider.isUserInteracting,
      isTrue,
      reason:
          'the second arm should have restarted the 50ms timer; '
          'without it the flag would have fallen to false at t=50ms',
    );
    provider.dispose();
  });
}
