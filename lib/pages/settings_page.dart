import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/no_focus_icon_button.dart';
import 'general_tab.dart';
import 'memory_tab.dart';
import 'providers_tab.dart';
import 'roles_tab.dart';
import 'skills_tab.dart';
import 'timers_tab.dart';
import 'tools_tab.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.settingsTitle),
          leading: NoFocusIconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: l10n.settingsTabGeneral),
              Tab(text: l10n.settingsTabProvider),
              Tab(text: l10n.settingsTabRole),
              Tab(text: l10n.settingsTabTools),
              Tab(text: l10n.settingsTabTimers),
              Tab(text: l10n.settingsTabSkill),
              Tab(text: l10n.settingsTabMemory),
            ],
          ),
        ),
        body: Consumer<SettingsProvider>(
          builder: (context, settings, _) {
            return TabBarView(
              children: [
                const GeneralTab(),
                ProvidersTab(
                  settings: settings,
                  onChanged: () {
                    context.read<ChatProvider>().clearMessages();
                  },
                ),
                RolesTab(settings: settings),
                ToolsTab(settings: settings),
                const TimersTab(),
                SkillsTab(settings: settings),
                const MemoryTab(),
              ],
            );
          },
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.text, required this.icon});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: context.textSecondary.withValues(alpha: 0.6),
            ),
            SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: context.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
