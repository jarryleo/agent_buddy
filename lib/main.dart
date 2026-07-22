import 'package:desktop_multi_window/desktop_multi_window.dart';
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
import 'pages/pet_window_page.dart';
import 'providers/chat_provider.dart';
import 'providers/memory_provider.dart';
import 'providers/pet_animation_hooks.dart';
import 'providers/pet_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/tts_service.dart';
import 'services/builtin_model_download_service.dart';
import 'services/chat_session_repository.dart';
import 'services/download_service.dart';
import 'services/file_attachment_service.dart';
import 'services/google_sheets_service.dart';
import 'services/image_service.dart';
import 'services/local_llm_service.dart';
import 'services/memory_repository.dart';
import 'services/notification_service.dart';
import 'services/pet_service.dart';
import 'services/platform/notes_service.dart';
import 'services/platform/tasks_service.dart';
import 'services/platform/autostart_service.dart';
import 'services/platform/autostart_service_io.dart';
import 'services/pet_window_controller.dart';
import 'services/storage_service.dart';
import 'services/sub_agent_service.dart';
import 'services/platform/voice_service.dart';
import 'services/platform/voice_service_factory.dart';
import 'services/timer_service.dart';
import 'services/tool_service.dart';
import 'theme/app_theme.dart';
import 'widgets/notification_host.dart';
import 'widgets/phone_frame.dart';

Future<void> main(List<String> args) async {
  // `desktop_multi_window` respawns `main()` for every sub-window.
  // Sub-windows pass `--type=pet` (defined in pet_window_page.dart)
  // so we can route them into the pet-window bootstrap before
  // touching `Hive` or the settings provider — the pet window only
  // needs `PetService`, not the full app plumbing.
  if (args.isNotEmpty) {
    for (final token in args) {
      if (token == '--type=$petWindowType') {
        final controller = await WindowController.fromCurrentEngine();
        await runPetWindow(controller);
        return;
      }
    }
  }

  await mainApp();
}

Future<void> mainApp() async {
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
  // Eagerly probe the TTS engine so the per-bubble speaker button
  // knows whether to show before its first render. Without this,
  // [TtsService.isSupported] starts as `false` and the bubble has
  // no other trigger to flip it — the user would see no speaker UI
  // even on platforms where the engine is fully wired up
  // (e.g. Windows SAPI, macOS AVSpeechSynthesizer). The probe is
  // fast on every supported platform (≤ 100 ms) so the startup
  // cost is negligible.
  //
  // Built first and registered via `Provider.value` below so the
  // widget tree sees the same instance the eager probe warmed up
  // — a plain `Provider(create: ...)` would create a *second*
  // instance whose probe hasn't run yet, re-introducing the bug.
  final ttsService = TtsService()..initialize();
  final timerService = TimerService();
  final googleSheets = GoogleSheetsService(storage: storage)..load();
  // Long-lived built-in model download service. Lives for the
  // app's lifetime so background downloads (the user navigates
  // away from the settings page) can keep running, and so
  // re-opening the page reattaches to the in-flight state
  // instead of starting a fresh download.
  final builtinDownloadService = BuiltinModelDownloadService();
  // Desktop-only "launch at login" service. Built eagerly so
  // SettingsProvider can re-apply the user's persisted choice
  // on every cold start (see [SettingsProvider.attachAutostartService]).
  // The factory returns a stub on mobile / web — the whole
  // surface is gated to desktop in the settings UI.
  final autostartService = createAutostartService();
  // Pet service is owned by the main isolate (the pet window is a
  // separate Flutter engine, see `runPetWindow`). Materialising
  // the built-in Anya here means the user gets the bundled pet
  // even if the pet window is launched later.
  final petService = PetService();
  runApp(
    AgentBuddyApp(
      storage: storage,
      notesBox: notesBox,
      tasksBox: tasksBox,
      memoriesBox: memoriesBox,
      memoryRepo: memoryRepo,
      ttsService: ttsService,
      timerService: timerService,
      googleSheets: googleSheets,
      builtinDownloadService: builtinDownloadService,
      autostartService: autostartService,
      petService: petService,
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

class AgentBuddyApp extends StatefulWidget {
  const AgentBuddyApp({
    super.key,
    required this.storage,
    required this.notesBox,
    required this.tasksBox,
    required this.memoriesBox,
    required this.memoryRepo,
    required this.ttsService,
    required this.timerService,
    required this.googleSheets,
    required this.builtinDownloadService,
    required this.autostartService,
    required this.petService,
  });

  final StorageService storage;
  final Box<Note> notesBox;
  final Box<Task> tasksBox;
  final Box<Memory> memoriesBox;
  final MemoryRepository memoryRepo;
  final TtsService ttsService;
  final TimerService timerService;
  final GoogleSheetsService googleSheets;
  final BuiltinModelDownloadService builtinDownloadService;
  final AutostartService autostartService;
  final PetService petService;

  @override
  State<AgentBuddyApp> createState() => _AgentBuddyAppState();
}

class _AgentBuddyAppState extends State<AgentBuddyApp> {
  late final SettingsProvider _settings;
  PetWindowController? _petController;

  @override
  void initState() {
    super.initState();
    _settings = SettingsProvider(
      widget.storage,
      widget.googleSheets,
      widget.autostartService,
    )..load()
      ..attachAutostartService(widget.autostartService);
    if (petWindowSupportedOnCurrentPlatform()) {
      _petController = PetWindowController(settings: _settings)
        ..syncOnStart();
    }
  }

  @override
  void dispose() {
    // Fire-and-forget: the controller closes the sub-window on
    // disposal. We can't await in dispose(), so swallow the
    // future.
    // ignore: discarded_futures
    _petController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsProvider>.value(value: _settings),
        ChangeNotifierProvider<PetProvider>(
          create: (_) => PetProvider(widget.petService),
        ),
        Provider<ApiService>(create: (_) => ApiService()),
        ChangeNotifierProvider<TimerService>.value(value: widget.timerService),
        ChangeNotifierProvider<GoogleSheetsService>.value(
          value: widget.googleSheets,
        ),
        ChangeNotifierProvider<BuiltinModelDownloadService>.value(
          value: widget.builtinDownloadService,
        ),
        Provider<ImageService>(create: (_) => ImageService()),
        Provider<FileAttachmentService>(create: (_) => FileAttachmentService()),
        Provider<DownloadService>(create: (_) => DownloadService()),
        Provider<VoiceService>(create: (_) => createVoiceService()),
        Provider<TtsService>.value(value: widget.ttsService),
        ChangeNotifierProvider<MemoryProvider>(
          create: (_) => MemoryProvider(widget.memoryRepo),
        ),
        ChangeNotifierProvider<LocalLlmService>(
          create: (_) => LocalLlmService(),
        ),
        // The sub-agent service is the runner the `subagent`
        // tool uses to delegate research / information-gathering
        // tasks to an isolated AI lane. We declare it before
        // ToolService so the ProxyProvider below can inject it.
        // Lazy construction means the local LLM's heavy
        // native-assets download doesn't fire on cold start
        // until the user actually invokes the sub-agent tool.
        //
        // We use `ListenableProvider` (not `Provider`) because
        // [SubAgentService] extends [ChangeNotifier] — Provider
        // refuses to host a `Listenable` for safety, since a
        // plain `Provider` won't re-publish on `notifyListeners`
        // and would silently drop updates. The chat provider is
        // the only thing that listens; UI never needs to
        // rebuild on sub-agent notifications, so we just need
        // a provider that accepts the type.
        ListenableProvider<SubAgentService>(
          create: (ctx) => SubAgentService(
            apiService: ctx.read<ApiService>(),
            localLlmService: ctx.read<LocalLlmService>(),
          ),
          lazy: true,
        ),
        // ToolService depends on SubAgentService; we use a
        // ProxyProvider so the dependency is wired automatically
        // (and stays consistent if either instance is ever
        // rebuilt by a hot-reload).
        ProxyProvider<SubAgentService, ToolService>(
          update: (_, subAgent, prev) =>
              prev ??
              ToolService(
                notesBox: widget.notesBox,
                tasksBox: widget.tasksBox,
                memoriesBox: widget.memoriesBox,
                timerService: widget.timerService,
                storage: widget.storage,
                googleSheets: widget.googleSheets,
                subAgent: subAgent,
              ),
        ),
        ChangeNotifierProxyProvider6<
          SettingsProvider,
          ApiService,
          ToolService,
          ImageService,
          DownloadService,
          FileAttachmentService,
          ChatProvider
        >(
          create: (ctx) => ChatProvider(
            widget.storage,
            ctx.read<ApiService>(),
            ctx.read<ToolService>(),
            ctx.read<ImageService>(),
            ctx.read<LocalLlmService>(),
            ctx.read<SettingsProvider>(),
            ctx.read<DownloadService>(),
            ctx.read<FileAttachmentService>(),
            petHooks: petAnimationHooksFromController(_petController),
          ),
          update: (ctx, settings, api, tools, images, downloads, files, prev) =>
              prev ??
              ChatProvider(
                widget.storage,
                api,
                tools,
                images,
                ctx.read<LocalLlmService>(),
                settings,
                downloads,
                files,
                petHooks: petAnimationHooksFromController(_petController),
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