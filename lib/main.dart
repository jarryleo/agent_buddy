import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/app_localizations.dart';
import 'models/memory.dart';
import 'models/memory_adapter.dart';
import 'models/note.dart';
import 'models/note_adapter.dart';
import 'models/task.dart';
import 'models/task_adapter.dart';
import 'pages/home_page.dart';
import 'providers/chat_provider.dart';
import 'providers/memory_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/builtin_model_download_service.dart';
import 'services/chat_session_repository.dart';
import 'services/download_service.dart';
import 'services/google_sheets_service.dart';
import 'services/image_service.dart';
import 'services/local_llm_service.dart';
import 'services/memory_repository.dart';
import 'services/notification_service.dart';
import 'services/platform/notes_service.dart';
import 'services/platform/tasks_service.dart';
import 'services/storage_service.dart';
import 'services/timer_service.dart';
import 'services/tool_service.dart';
import 'theme/app_theme.dart';
import 'widgets/notification_host.dart';
import 'widgets/phone_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _setupDesktopWindow();
  await Hive.initFlutter();
  ChatSessionRepository.registerAdapters();
  if (!Hive.isAdapterRegistered(2)) {
    Hive.registerAdapter(NoteAdapter());
  }
  if (!Hive.isAdapterRegistered(3)) {
    Hive.registerAdapter(TaskAdapter());
  }
  if (!Hive.isAdapterRegistered(4)) {
    Hive.registerAdapter(MemoryAdapter());
  }
  // Built-in notes / tasks / memories boxes. They are opened here
  // so the ToolService can read / write to them on the first call
  // without blocking on a Hive lazy-open. Hive is happy to open an
  // empty box on first launch.
  final notesBox = await Hive.openBox<Note>(NotesService.boxName);
  final tasksBox = await Hive.openBox<Task>(TasksService.boxName);
  final memoriesBox = await Hive.openBox<Memory>(MemoryRepository.boxName);
  final memoryRepo = MemoryRepository()..open(preopened: memoriesBox);
  final storage = StorageService();
  await storage.init();
  // Notification / timer services own no platform channels at
  // startup. NotificationService.initialize() is best-effort and
  // called on first show(); TimerService just holds an in-memory
  // queue.
  await NotificationService.instance.initialize();
  final timerService = TimerService();
  final googleSheets = GoogleSheetsService(storage: storage)..load();
  // Long-lived built-in model download service. Lives for the
  // app's lifetime so background downloads (the user navigates
  // away from the settings page) can keep running, and so
  // re-opening the page reattaches to the in-flight state
  // instead of starting a fresh download.
  final builtinDownloadService = BuiltinModelDownloadService();
  runApp(
    AgentBuddyApp(
      storage: storage,
      notesBox: notesBox,
      tasksBox: tasksBox,
      memoriesBox: memoriesBox,
      memoryRepo: memoryRepo,
      timerService: timerService,
      googleSheets: googleSheets,
      builtinDownloadService: builtinDownloadService,
    ),
  );
}

/// Constrains the OS-level desktop window so it cannot be resized wider
/// than a phone screen and cannot be maximized. No-op on mobile / web.
Future<void> _setupDesktopWindow() async {
  if (defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.windows &&
      defaultTargetPlatform != TargetPlatform.linux) {
    return;
  }
  await windowManager.ensureInitialized();
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(400, 800),
      center: true,
      minimumSize: Size(320, 568),
      // Width is the real ceiling (matches PhoneFrame.maxWidth). Height is
      // intentionally left effectively unbounded so only width is capped.
      maximumSize: Size(480, 10000),
      title: 'Agent Buddy',
    ),
    () {
      // FIFO method channel: maximizable / resizable are applied before show().
      windowManager.setMaximizable(false);
      windowManager.setResizable(true);
      windowManager.show();
      windowManager.focus();
    },
  );
}

class AgentBuddyApp extends StatelessWidget {
  const AgentBuddyApp({
    super.key,
    required this.storage,
    required this.notesBox,
    required this.tasksBox,
    required this.memoriesBox,
    required this.memoryRepo,
    required this.timerService,
    required this.googleSheets,
    required this.builtinDownloadService,
  });
  final StorageService storage;
  final Box<Note> notesBox;
  final Box<Task> tasksBox;
  final Box<Memory> memoriesBox;
  final MemoryRepository memoryRepo;
  final TimerService timerService;
  final GoogleSheetsService googleSheets;
  final BuiltinModelDownloadService builtinDownloadService;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(storage, googleSheets)..load(),
        ),
        Provider<ApiService>(create: (_) => ApiService()),
        ChangeNotifierProvider<TimerService>.value(value: timerService),
        ChangeNotifierProvider<GoogleSheetsService>.value(value: googleSheets),
        ChangeNotifierProvider<BuiltinModelDownloadService>.value(
          value: builtinDownloadService,
        ),
        Provider<ToolService>(
          create: (_) => ToolService(
            notesBox: notesBox,
            tasksBox: tasksBox,
            memoriesBox: memoriesBox,
            timerService: timerService,
            storage: storage,
            googleSheets: googleSheets,
          ),
        ),
        Provider<ImageService>(create: (_) => ImageService()),
        Provider<DownloadService>(create: (_) => DownloadService()),
        ChangeNotifierProvider<MemoryProvider>(
          create: (_) => MemoryProvider(memoryRepo),
        ),
        ChangeNotifierProvider<LocalLlmService>(
          create: (_) => LocalLlmService(),
        ),
        ChangeNotifierProxyProvider5<
          SettingsProvider,
          ApiService,
          ToolService,
          ImageService,
          DownloadService,
          ChatProvider
        >(
          create: (ctx) => ChatProvider(
            storage,
            ctx.read<ApiService>(),
            ctx.read<ToolService>(),
            ctx.read<ImageService>(),
            ctx.read<LocalLlmService>(),
            ctx.read<SettingsProvider>(),
            ctx.read<DownloadService>(),
          ),
          update: (ctx, settings, api, tools, images, downloads, prev) =>
              prev ??
              ChatProvider(
                storage,
                api,
                tools,
                images,
                ctx.read<LocalLlmService>(),
                settings,
                downloads,
              ),
        ),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settings, _) {
          final isDark = settings.themeMode == 'dark';
          return MaterialApp(
            onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appTitle,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: _parseThemeMode(settings.themeMode),
            locale: _parseLocale(settings.localeCode),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en'), Locale('zh')],
            builder: (ctx, child) {
              // The `Key` here is load-bearing: `MaterialApp.builder`
              // is invoked on every `Consumer<SettingsProvider>`
              // rebuild (e.g. theme flip), and the framework has a
              // known assertion (`_InactiveElements.remove` — "is not
              // true") when an `AnnotatedRegion` is updated in-place
              // around a navigator child. A value-keyed element lets
              // Flutter dispose the old element and build a fresh
              // one on theme change instead of trying to retake an
              // inactive element that's no longer in the set.
              //
              // The `NotificationHost` wraps the navigator with a
              // bottom-right toast overlay so the desktop / web
              // notification path has a place to render. On mobile
              // the overlay is a no-op (real OS notifications are
              // used), but we still mount it so the wire-up is
              // identical across platforms.
              return NotificationHost(
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  key: ValueKey('system-ui-overlay-$isDark'),
                  value: SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent,
                    statusBarIconBrightness: isDark
                        ? Brightness.light
                        : Brightness.dark,
                    systemNavigationBarColor: isDark
                        ? const Color(0xFF0F1115)
                        : const Color(0xFFF6F7F9),
                    systemNavigationBarIconBrightness: isDark
                        ? Brightness.light
                        : Brightness.dark,
                    systemNavigationBarDividerColor: Colors.transparent,
                  ),
                  child: child ?? const SizedBox.shrink(),
                ),
              );
            },
            home: PhoneFrame(child: HomePage()),
          );
        },
      ),
    );
  }

  ThemeMode _parseThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  Locale? _parseLocale(String code) {
    if (code == 'system' || code.isEmpty) return null;
    return Locale(code);
  }
}
