import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/tool.dart';
import '../providers/settings_provider.dart';
import '../services/platform/reminders_service_io.dart';
import '../services/tool_service.dart';
import '../services/tools/tool_registry.dart';
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
      body: Column(
        children: [
          _MasterSwitchCard(
            enabled: settings.toolsEnabled,
            onChanged: (v) => settings.setToolsEnabled(v),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 24),
              itemCount: tools.length,
              separatorBuilder: (_, _) => SizedBox(height: 10),
              itemBuilder: (context, index) {
                final t = tools[index];
                final active = settings.activeToolIds.contains(t.id);
                final toolDef = ToolRegistry.byId(t.id);
                final name = toolDef?.name ?? t.name;
                final description = toolDef?.description ?? t.description;
                return _ToolCard(
                  tool: t,
                  active: active,
                  name: name,
                  description: description,
                  masterEnabled: settings.toolsEnabled,
                  onToggle: (v) async {
                    if (t.id == 'reminders' && v) {
                      // On Android the reminders tool needs a
                      // "todo" calendar to be picked. We pop the
                      // picker **every time** the user flips the
                      // switch on (not just the first time) so
                      // they can switch the backing calendar
                      // whenever they want. If they cancel the
                      // sheet, we roll the switch back to off so
                      // the UI stays consistent with reality.
                      final picked = await _promptForTodoCalendar(
                        context,
                      );
                      if (picked == null) return;
                      if (!context.mounted) return;
                      await settings.toggleTool(t.id, true);
                      return;
                    }
                    await settings.toggleTool(t.id, v);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Always show the calendar picker when the user enables the
  /// reminders tool. Returns the picked calendar id, or `null` if
  /// the user dismissed the sheet (in which case the caller should
  /// NOT toggle the tool on). On iOS the picker is a no-op because
  /// the system Reminders framework owns the storage; we return
  /// the synthetic `ios_default` id so the toggle can proceed.
  Future<String?> _promptForTodoCalendar(BuildContext context) async {
    final tools = context.read<ToolService>();
    final reminders = tools.reminders;
    if (reminders is! RemindersServiceIo) {
      // iOS path — no picker needed, the system Reminders store is
      // the single canonical container. Fall through and let the
      // caller enable the tool.
      return 'ios_default';
    }
    final picked = await ReminderCalendarPickerSheet.show(context, reminders);
    if (picked == null) return null;
    await reminders.setTodoCalendar(picked);
    return picked;
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

/// Master "use tools" switch rendered at the top of the Tools tab.
/// When off, the whole tool stack is disabled (no schemas sent to
/// the model, no tool-related guidance in the system prompt, and
/// every per-tool card below is dimmed + non-interactive). Each
/// tool's individual switch is preserved so flipping the master
/// back on restores the previous selection.
class _MasterSwitchCard extends StatelessWidget {
  const _MasterSwitchCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Material(
        color: enabled
            ? AppTheme.primary.withValues(alpha: 0.08)
            : context.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onChanged(!enabled),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: enabled
                    ? AppTheme.primary.withValues(alpha: 0.25)
                    : context.appBorder,
                width: enabled ? 1.0 : 0.6,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: enabled ? AppTheme.primary : context.appBorder,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    enabled ? Icons.handyman : Icons.do_disturb_alt_outlined,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.toolsMasterSwitchTitle,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: enabled ? AppTheme.primary : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        enabled
                            ? l10n.toolsMasterSwitchDescription
                            : l10n.toolsMasterOffHint,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(value: enabled, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in the tool list. Reflects the per-tool `enabled` flag
/// in its switch, but locks the switch (and greys the row) when
/// the master switch above is off, so the user has to re-enable
/// tools globally before they can flip individual tools.
class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.tool,
    required this.active,
    required this.name,
    required this.description,
    required this.masterEnabled,
    required this.onToggle,
  });

  final AgentTool tool;
  final bool active;
  final String name;
  final String description;
  final bool masterEnabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final dimmed = !masterEnabled;
    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: IgnorePointer(
        ignoring: dimmed,
        child: Material(
          color: context.surface,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active && masterEnabled
                    ? AppTheme.primary
                    : context.appBorder,
                width: active && masterEnabled ? 1.4 : 0.6,
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
                  value: tool.enabled,
                  onChanged: dimmed ? null : onToggle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
