import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/chat_session.dart';
import '../providers/chat_provider.dart';
import '../theme/app_theme.dart';
import 'no_focus_icon_button.dart';

/// Bottom-sheet style session manager. Shown from the home page
/// "Sessions" button.
///
/// Layout:
///   - top bar: title + "select all / clear / delete" + close
///   - new-session button (sticky, full width)
///   - scrollable list of session rows (radio + title + timestamp)
///   - rows can be individually long-pressed to enter
///     multi-select mode for batch delete
class SessionManagerSheet extends StatefulWidget {
  const SessionManagerSheet({super.key});

  /// Show the sheet using the closest `Navigator` and return when
  /// the user dismisses it.
  static Future<void> show(BuildContext context) {
    final chat = context.read<ChatProvider>();
    chat.refreshSessionList();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChangeNotifierProvider<ChatProvider>.value(
        value: chat,
        child: const SessionManagerSheet(),
      ),
    );
  }

  @override
  State<SessionManagerSheet> createState() => _SessionManagerSheetState();
}

class _SessionManagerSheetState extends State<SessionManagerSheet> {
  /// Set of session ids selected for batch delete.
  final Set<String> _selected = {};
  bool _multiSelect = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chat = context.watch<ChatProvider>();
    final sessions = chat.sessions;
    final activeId = chat.activeSessionId;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(16),
            ),
          ),
          child: Column(
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.appBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Top bar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.sessionManagerTitle,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_multiSelect) ...[
                      TextButton(
                        onPressed: () {
                          setState(() {
                            if (_selected.length == sessions.length) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(sessions.map((s) => s.id));
                            }
                          });
                        },
                        child: Text(
                          _selected.length == sessions.length
                              ? l10n.sessionManagerDeselectAll
                              : l10n.sessionManagerSelectAll,
                        ),
                      ),
                      TextButton(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => _confirmAndDelete(chat, _selected.toList()),
                        child: Text(
                          l10n.sessionManagerDelete,
                          style: TextStyle(
                            color: _selected.isEmpty
                                ? context.textSecondary
                                : Colors.red,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _multiSelect = false;
                            _selected.clear();
                          });
                        },
                        child: Text(l10n.commonCancel),
                      ),
                    ] else
                      NoFocusIconButton(
                        icon: const Icon(Icons.close_rounded),
                        tooltip: l10n.commonCancel,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                  ],
                ),
              ),
              // New session button
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      await chat.createNewSession();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(l10n.sessionManagerNew),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: context.appBorder),
              // List
              Expanded(
                child: sessions.isEmpty
                    ? Center(
                        child: Text(
                          l10n.sessionManagerEmpty,
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: sessions.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: context.appBorder),
                        itemBuilder: (context, index) {
                          final s = sessions[index];
                          final isActive = s.id == activeId;
                          final isSelected = _selected.contains(s.id);
                          return _SessionRow(
                            session: s,
                            isActive: isActive,
                            multiSelect: _multiSelect,
                            selected: isSelected,
                            onTap: () async {
                              if (_multiSelect) {
                                setState(() {
                                  if (isSelected) {
                                    _selected.remove(s.id);
                                  } else {
                                    _selected.add(s.id);
                                  }
                                });
                                return;
                              }
                              await chat.selectSession(s.id);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                            onLongPress: () {
                              setState(() {
                                _multiSelect = true;
                                _selected.add(s.id);
                              });
                            },
                            onDelete: () =>
                                _confirmAndDelete(chat, [s.id]),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmAndDelete(ChatProvider chat, List<String> ids) async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          ids.length == 1
              ? l10n.sessionManagerDeleteConfirmTitle
              : l10n.sessionManagerDeleteBatchConfirmTitle(ids.length),
        ),
        content: Text(l10n.sessionManagerDeleteMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              l10n.commonDelete,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await chat.deleteSessions(ids);
      if (!mounted) return;
      setState(() {
        _multiSelect = false;
        _selected.clear();
      });
    }
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.isActive,
    required this.multiSelect,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onDelete,
  });

  final ChatSession session;
  final bool isActive;
  final bool multiSelect;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDelete;

  String _formatTimestamp(DateTime t, BuildContext context) {
    final now = DateTime.now();
    final local = t.toLocal();
    if (now.year == local.year &&
        now.month == local.month &&
        now.day == local.day) {
      return DateFormat('HH:mm').format(local);
    }
    if (now.difference(local).inDays < 7) {
      return DateFormat('E HH:mm', Localizations.localeOf(context).toString())
          .format(local);
    }
    return DateFormat('yyyy-MM-dd HH:mm').format(local);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected
            ? AppTheme.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            if (multiSelect)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  selected
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded,
                  size: 20,
                  color: selected ? AppTheme.primary : context.textSecondary,
                ),
              )
            else if (isActive)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.chat_bubble_rounded,
                  size: 18,
                  color: AppTheme.primary,
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 18,
                  color: Color(0xFF8B949E),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: isActive ? AppTheme.primary : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatTimestamp(session.updatedAt, context),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (!multiSelect)
              NoFocusIconButton(
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: context.textSecondary,
                ),
                tooltip: l10n.commonDelete,
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}
