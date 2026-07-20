import 'dart:io';

import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/chat_session.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:agent_buddy/pages/add_provider_page.dart';
import 'package:agent_buddy/pages/settings_page.dart';
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
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tempDir;
  late StorageService storage;

  setUpAll(ChatSessionRepository.registerAdapters);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('chat_tools_settings_');
    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await storage.sessions.close();
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    await tempDir.delete(recursive: true);
  });

  test('working directory and thinking mode persist', () async {
    final settings = SettingsProvider(storage);
    await settings.load();
    await settings.setModelWorkingDirectory(path: 'C:/workspace/project');
    await settings.setThinkingModeEnabled(true);

    final restored = SettingsProvider(storage);
    await restored.load();

    expect(restored.modelWorkingDirectory, 'C:/workspace/project');
    expect(restored.thinkingModeEnabled, isTrue);
    expect(
      ToolService(storage: storage).workingDirectory,
      'C:/workspace/project',
    );

    final toolService = ToolService(storage: storage);
    addTearDown(toolService.dispose);
  });

  testWidgets('model configuration changes preserve the current chat', (
    tester,
  ) async {
    final settings = SettingsProvider(storage);
    await settings.load();
    final provider = await settings.addProvider(
      name: 'Preserve Chat Model',
      protocol: ProviderProtocol.openai,
      baseUrl: 'https://example.com/v1',
      apiKey: 'test-key',
      chatPath: '/chat/completions',
    );
    await settings.updateProvider(
      provider.copyWith(models: ['model-a'], selectedModel: 'model-a'),
    );

    final now = DateTime.now();
    final session = ChatSession(
      id: 'active-session',
      title: 'Existing chat',
      createdAt: now,
      updatedAt: now,
      messages: [
        ChatMessage(
          id: 'message-1',
          role: MessageRole.user,
          content: 'Keep this message',
        ),
      ],
    );
    await tester.runAsync(() async {
      await storage.sessions.save(session);
      await storage.setActiveSessionId(session.id);
    });

    final api = ApiService();
    final tools = ToolService(storage: storage);
    final localLlm = LocalLlmService();
    final downloads = DownloadService();
    final chat = ChatProvider(
      storage,
      api,
      tools,
      ImageService(),
      localLlm,
      settings,
      downloads,
      FileAttachmentService(),
    );
    addTearDown(() {
      chat.dispose();
      downloads.dispose();
      localLlm.dispose();
      tools.dispose();
      api.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<ChatProvider>.value(value: chat),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: const SettingsPage(),
        ),
      ),
    );

    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preserve Chat Model'));
    await tester.pumpAndSettle();
    expect(find.byType(AddProviderPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(chat.activeSessionId, session.id);
    expect(chat.messages, hasLength(1));
    expect(chat.messages.single.content, 'Keep this message');
    expect(storage.sessions.get(session.id)?.messages, hasLength(1));
  });
}
