import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'pages/home_page.dart';
import 'providers/chat_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/chat_session_repository.dart';
import 'services/image_service.dart';
import 'services/local_llm_service.dart';
import 'services/storage_service.dart';
import 'services/tool_service.dart';
import 'theme/app_theme.dart';
import 'widgets/phone_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  ChatSessionRepository.registerAdapters();
  final storage = StorageService();
  await storage.init();
  runApp(AgentBuddyApp(storage: storage));
}

class AgentBuddyApp extends StatelessWidget {
  const AgentBuddyApp({super.key, required this.storage});
  final StorageService storage;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(storage)..load(),
        ),
        Provider<ApiService>(create: (_) => ApiService()),
        Provider<ToolService>(create: (_) => ToolService()),
        Provider<ImageService>(create: (_) => ImageService()),
        ChangeNotifierProvider<LocalLlmService>(
          create: (_) => LocalLlmService(),
        ),
        ChangeNotifierProxyProvider4<
          SettingsProvider,
          ApiService,
          ToolService,
          ImageService,
          ChatProvider
        >(
          create: (ctx) => ChatProvider(
            storage,
            ctx.read<ApiService>(),
            ctx.read<ToolService>(),
            ctx.read<ImageService>(),
            ctx.read<LocalLlmService>(),
            ctx.read<SettingsProvider>(),
          ),
          update: (ctx, settings, api, tools, images, prev) =>
              prev ??
              ChatProvider(
                storage,
                api,
                tools,
                images,
                ctx.read<LocalLlmService>(),
                settings,
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
              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: SystemUiOverlayStyle(
                  statusBarColor: Colors.transparent,
                  statusBarIconBrightness:
                      isDark ? Brightness.light : Brightness.dark,
                  systemNavigationBarColor: isDark
                      ? const Color(0xFF0F1115)
                      : const Color(0xFFF6F7F9),
                  systemNavigationBarIconBrightness:
                      isDark ? Brightness.light : Brightness.dark,
                  systemNavigationBarDividerColor: Colors.transparent,
                ),
                child: child ?? const SizedBox.shrink(),
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
