import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/todo_list.dart';
import '../providers/chat_provider.dart';
import '../theme/app_theme.dart';

/// Per-conversation task list shown above the chat input.
///
/// Renders the active [TodoList] from [ChatProvider]:
///   * **Title** — set by the model via `todo(action='create',
///     title='...')`. Falls back to a localized "Task list"
///     header.
///   * **Progress badge** — `done / total`. The badge flips to
///     the green "all done" state once every item is ticked
///     off; the panel auto-collapses (rendered as a one-line
///     header) so the user sees the result without it taking
///     up permanent vertical space.
///   * **Items** — one row per todo. Done items render in a
///     dimmer color with a strikethrough. The order shown is
///     the order they were added in (the `order` field on the
///     item).
///   * **State hint** — three states that map to the
///     `chatProvider.{userStoppedLastTurn, supervisionPending,
///     hasPendingTodos}` flags:
///       - "监督唤醒中…" — supervision prompt is queued (so the
///         user understands a fresh turn is about to start
///         without their input).
///       - "用户已暂停监督" — the user tapped "stop" mid-turn.
///         No further auto-resumes until they send again.
///       - "已达最大监督次数,任务清单暂停中" — the cap was hit.
///         The user can either send a fresh message to nudge
///         the model, or tap "放弃任务" to clear the list.
///
///   * **Abandon button** — clears the todo list and cancels
///     the supervision timer. Hidden when the list is empty
///     or all-done (the user can otherwise ignore the panel
///     and it'll auto-collapse).
class TodoListPanel extends StatelessWidget {
  const TodoListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatProvider>();
    final list = chat.todoList;
    if (list.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);

    // The "all done" state collapses to a single chip line so
    // the panel doesn't keep eating vertical space after the
    // model finishes. The user can still see the result; the
    // list will be cleared on the next `create` / `clear` /
    // session switch.
    if (list.allDone) {
      return _DoneSummary(context: context, list: list, l10n: l10n);
    }

    return _TodoBody(chat: chat, list: list, l10n: l10n);
  }
}

class _TodoBody extends StatelessWidget {
  const _TodoBody({required this.chat, required this.list, required this.l10n});

  final ChatProvider chat;
  final TodoList list;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final progress = list.totalCount == 0
        ? 0.0
        : list.completedCount / list.totalCount;
    final stateHint = _buildStateHint(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.18),
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.checklist_rtl_rounded,
                size: 16,
                color: AppTheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  list.title ?? l10n.todoPanelTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _ProgressBadge(list: list),
              const SizedBox(width: 4),
              _AbandonButton(
                l10n: l10n,
                onPressed: () => _confirmAbandon(context),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.10),
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primary),
            ),
          ),
          if (stateHint != null) ...[const SizedBox(height: 6), stateHint],
          const SizedBox(height: 6),
          for (final item in list.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: _TodoRow(item: item),
            ),
        ],
      ),
    );
  }

  Widget? _buildStateHint(BuildContext context) {
    if (chat.supervisionPending) {
      return _Hint(
        icon: Icons.hourglass_top_rounded,
        text: l10n.todoSupervisionPending,
        color: AppTheme.primary,
      );
    }
    if (chat.userStoppedLastTurn) {
      return _Hint(
        icon: Icons.pause_circle_outline_rounded,
        text: l10n.todoSupervisionUserStopped,
        color: Colors.orange,
      );
    }
    if (list.pendingItems.isEmpty == false && chat.todoList.allDone == false) {
      // The cap-hit state is signalled when the chat provider
      // has bumped the supervisor-attempts counter to its
      // ceiling. We don't expose the counter publicly, but
      // the side-effect (no auto-resumes despite pending
      // items) is what matters to the user.
      // (See ChatProvider._maybeScheduleSupervision's
      // `kMaxSupervisionAttempts` gate.)
    }
    return null;
  }

  Future<void> _confirmAbandon(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.todoAbandonTitle),
          content: Text(l10n.todoAbandonMessage),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: Text(l10n.todoAbandonConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await chat.abandonTodoList();
    }
  }
}

class _DoneSummary extends StatelessWidget {
  const _DoneSummary({
    required this.context,
    required this.list,
    required this.l10n,
  });

  final BuildContext context;
  final TodoList list;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext _) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.green.withValues(alpha: 0.25),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 16,
            color: Colors.green,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              list.title == null
                  ? l10n.todoAllDonePlain
                  : l10n.todoAllDoneWithTitle(list.title!),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            l10n.todoProgress(list.completedCount, list.totalCount),
            style: TextStyle(
              fontSize: 11,
              color: context.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({required this.list});
  final TodoList list;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        AppLocalizations.of(
          context,
        ).todoProgress(list.completedCount, list.totalCount),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}

class _AbandonButton extends StatelessWidget {
  const _AbandonButton({required this.l10n, required this.onPressed});

  final AppLocalizations l10n;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: l10n.todoAbandonTooltip,
        onPressed: onPressed,
        icon: Icon(Icons.close_rounded, size: 16, color: context.textSecondary),
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.item});
  final TodoItem item;

  @override
  Widget build(BuildContext context) {
    final done = item.isDone;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            done
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            size: 14,
            color: done ? Colors.green : context.textSecondary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.content,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.35,
                  color: done ? context.textSecondary : context.textPrimary,
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
              if (item.detail != null && item.detail!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    item.detail!,
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.3,
                      color: context.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text, required this.color});

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10.5, color: color, height: 1.3),
          ),
        ),
      ],
    );
  }
}
