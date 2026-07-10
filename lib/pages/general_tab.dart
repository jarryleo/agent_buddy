import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

const String _kAppVersion = '1.0.1';

class GeneralTab extends StatelessWidget {
  const GeneralTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = context.watch<SettingsProvider>();
    return Scaffold(
      backgroundColor: context.bg,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          SectionTitle(l10n.generalSectionAppearance),
          _GroupedCard(
            children: [
              _ThemeRow(
                current: settings.themeMode,
                onChanged: settings.setThemeMode,
                l10n: l10n,
              ),
            ],
          ),
          SectionTitle(l10n.generalSectionLanguage),
          _GroupedCard(
            children: [
              _LanguageRow(
                current: settings.localeCode,
                onChanged: settings.setLocaleCode,
                l10n: l10n,
              ),
            ],
          ),
          SectionTitle(l10n.generalSectionAbout),
          _AboutCard(l10n: l10n),
        ],
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  const _GroupedCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Column(children: children),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.current,
    required this.onChanged,
    required this.l10n,
  });

  final String current;
  final ValueChanged<String> onChanged;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showPicker(context),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Icon(
              Icons.dark_mode_outlined,
              size: 20,
              color: context.textPrimary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.generalDarkMode,
                style: TextStyle(fontSize: 14, color: context.textPrimary),
              ),
            ),
            Text(
              _labelFor(current),
              style: TextStyle(fontSize: 13, color: context.textSecondary),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: context.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  String _labelFor(String mode) {
    switch (mode) {
      case 'light':
        return l10n.generalThemeLight;
      case 'dark':
        return l10n.generalThemeDark;
      default:
        return l10n.generalThemeSystem;
    }
  }

  Future<void> _showPicker(BuildContext context) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in const ['system', 'light', 'dark'])
                ListTile(
                  title: Text(
                    m == 'system'
                        ? l10n.generalThemeSystem
                        : m == 'light'
                        ? l10n.generalThemeLight
                        : l10n.generalThemeDark,
                  ),
                  trailing: current == m
                      ? Icon(Icons.check, color: AppTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, m),
                ),
            ],
          ),
        );
      },
    );
    if (pick != null) onChanged(pick);
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.current,
    required this.onChanged,
    required this.l10n,
  });

  final String current;
  final ValueChanged<String> onChanged;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _showPicker(context),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Icon(Icons.language_rounded, size: 20, color: context.textPrimary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.generalSectionLanguage,
                style: TextStyle(fontSize: 14, color: context.textPrimary),
              ),
            ),
            Text(
              _labelFor(current),
              style: TextStyle(fontSize: 13, color: context.textSecondary),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: context.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  String _labelFor(String code) {
    switch (code) {
      case 'en':
        return l10n.generalLanguageEn;
      case 'zh':
        return l10n.generalLanguageZh;
      default:
        return l10n.generalLanguageSystem;
    }
  }

  Future<void> _showPicker(BuildContext context) async {
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in const ['system', 'en', 'zh'])
                ListTile(
                  title: Text(
                    c == 'system'
                        ? l10n.generalLanguageSystem
                        : c == 'en'
                        ? l10n.generalLanguageEn
                        : l10n.generalLanguageZh,
                  ),
                  trailing: current == c
                      ? Icon(Icons.check, color: AppTheme.primary)
                      : null,
                  onTap: () => Navigator.pop(ctx, c),
                ),
            ],
          ),
        );
      },
    );
    if (pick != null) onChanged(pick);
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.l10n});
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.bolt_rounded, size: 30, color: AppTheme.primary),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.generalAboutAppName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.generalAboutTagline,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.textSecondary),
          ),
          const SizedBox(height: 10),
          Text(
            l10n.generalAboutVersion(_kAppVersion),
            style: TextStyle(
              fontSize: 11,
              color: context.textSecondary.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }
}
