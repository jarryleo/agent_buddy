import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'pages/home_page.dart';
import 'providers/chat_provider.dart';
import 'providers/settings_provider.dart';
import 'services/api_service.dart';
import 'services/image_service.dart';
import 'services/local_llm_service.dart';
import 'services/storage_service.dart';
import 'services/tool_service.dart';
import 'theme/app_theme.dart';
import 'widgets/phone_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
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
        Provider<LocalLlmService>(
          create: (_) => LocalLlmService(),
          dispose: (_, svc) => svc.dispose(),
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
      child: MaterialApp(
        onGenerateTitle: (ctx) => AppLocalizations.of(ctx).appTitle,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        home: const PhoneFrame(child: HomePage()),
      ),
    );
  }
}
