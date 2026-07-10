import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/platform/reminders_service_io.dart';
import '../services/tool_service.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key, required this.settings});
  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tools = settings.tools;
    if (tools.isEmpty) {
      return EmptyHint(
        text: l10n.toolsListEmpty,
        icon: Icons.handyman_outlined,
      );
    }
    return Scaffold(
      backgroundColor: context.bg,
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: tools.length,
        separatorBuilder: (_, _) => SizedBox(height: 10),
        itemBuilder: (context, index) {
          final t = tools[index];
          final active = settings.activeToolIds.contains(t.id);
          final name = switch (t.id) {
            'fetch_web' => l10n.toolFetchWebName,
            'current_time' => l10n.toolCurrentTimeName,
            'ask_user' => l10n.toolAskUserName,
            'run_command' => l10n.toolRunCommandName,
            'get_environment' => l10n.toolGetEnvironmentName,
            'calendar' => l10n.toolCalendarName,
            'reminders' => l10n.toolRemindersName,
            'notes' => l10n.toolNotesName,
            'tasks' => l10n.toolTasksName,
            _ => t.name,
          };
          final description = switch (t.id) {
            'fetch_web' => l10n.toolFetchWebDescription,
            'current_time' => l10n.toolCurrentTimeDescription,
            'ask_user' => l10n.toolAskUserDescription,
            'run_command' => l10n.toolRunCommandDescription,
            'get_environment' => l10n.toolGetEnvironmentDescription,
            'calendar' => l10n.toolCalendarDescription,
            'reminders' => l10n.toolRemindersDescription,
            'notes' => l10n.toolNotesDescription,
            'tasks' => l10n.toolTasksDescription,
            _ => t.description,
          };
          return Material(
            color: context.surface,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active ? AppTheme.primary : context.appBorder,
                  width: active ? 1.4 : 0.6,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.handyman_outlined,
                      color: AppTheme.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: t.enabled,
                    onChanged: (v) async {
                      if (t.id == 'reminders' && v) {
                        await _maybePromptForTodoCalendar(context);
                      }
                      if (context.mounted) {
                        await settings.toggleTool(t.id, v);
                      }
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// On Android, the first time the user enables the reminders
  /// tool we ask them to pick a writable calendar as the "todo"
  /// container. If a calendar is already configured, this is a
  /// no-op. If the user has no writable calendar accounts (e.g.
  /// fresh device with no Google account), we surface a snackbar
  /// and let them try again later.
  Future<void> _maybePromptForTodoCalendar(BuildContext context) async {
    final tools = context.read<ToolService>();
    final reminders = tools.reminders;
    if (reminders is! RemindersServiceIo) return;
    try {
      final existing = await reminders.getTodoCalendar();
      if (existing != null) return;
    } on PlatformException {
      // Permission may not be granted yet — proceed to picker
      // which will trigger the system permission dialog.
    }
    if (!context.mounted) return;
    final picked = await ReminderCalendarPickerSheet.show(context, reminders);
    if (picked == null) return;
    await reminders.setTodoCalendar(picked);
  }
}

/// Bottom sheet that lists writable calendars on Android and lets
/// the user pick one as the reminders "todo" container. iOS hides
/// this entirely (the system Reminders framework is the store).
class ReminderCalendarPickerSheet extends StatelessWidget {
  const ReminderCalendarPickerSheet({super.key, required this.reminders});

  final RemindersServiceIo reminders;

  static Future<String?> show(
    BuildContext context,
    RemindersServiceIo reminders,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReminderCalendarPickerSheet(reminders: reminders),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scroll) {
        return Container(
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.appBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  l10n.remindersPickerTitle,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l10n.remindersPickerDescription,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<RemindersCalendarChoice>>(
                  future: reminders.listWritableCalendars(),
                  builder: (context, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      );
                    }
                    if (snap.hasError) {
                      return _ErrorState(
                        error: snap.error.toString(),
                        onRetry: () => (context as Element).markNeedsBuild(),
                      );
                    }
                    final list = snap.data ?? const [];
                    if (list.isEmpty) {
                      return _ErrorState(
                        error: l10n.remindersPickerEmpty,
                        onRetry: () => (context as Element).markNeedsBuild(),
                      );
                    }
                    return ListView.separated(
                      controller: scroll,
                      itemCount: list.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 20, endIndent: 20),
                      itemBuilder: (context, i) {
                        final c = list[i];
                        return ListTile(
                          title: Text(c.displayName),
                          subtitle: c.accountName.isEmpty
                              ? null
                              : Text(
                                  c.accountName,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.textSecondary,
                                  ),
                                ),
                          onTap: () => Navigator.of(context).pop(c.id),
                        );
                      },
                    );
                  },
                ),
              ),
              const SafeArea(top: false, child: SizedBox(height: 8)),
            ],
          ),
        );
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 36, color: context.textSecondary),
          const SizedBox(height: 12),
          Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: Text(l10n.commonConfirm)),
        ],
      ),
    );
  }
}
