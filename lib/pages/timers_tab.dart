import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/timer_task.dart';
import '../services/timer_service.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class TimersTab extends StatefulWidget {
  const TimersTab({super.key});

  @override
  State<TimersTab> createState() => _TimersTabState();
}

class _TimersTabState extends State<TimersTab> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final timers = context.watch<TimerService>();
    final all = timers.tasks;
    final visible = _showAll ? all : all.where((t) => t.isPending).toList();
    return Scaffold(
      backgroundColor: context.bg,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _RuntimeNote(text: l10n.timerNoteRuntime),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.timerHideTerminal,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSecondary,
                    ),
                  ),
                ),
                Switch(
                  value: _showAll,
                  onChanged: (v) => setState(() => _showAll = v),
                ),
                Text(
                  l10n.timerShowAll,
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? EmptyHint(
                    text: _showAll
                        ? l10n.timerListEmpty
                        : l10n.timerListEmptyFilter,
                    icon: Icons.timer_outlined,
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final t = visible[i];
                      return _TimerCard(
                        task: t,
                        onEdit: () => _openEdit(context, t),
                        onCancel: () => _confirmCancel(context, t),
                        onDelete: () => _confirmDelete(context, t),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
    );
  }

  Future<void> _openEdit(BuildContext context, [TimerTask? existing]) async {
    final l10n = AppLocalizations.of(context);
    final result = await Navigator.of(context).push<_TimerEditResult?>(
      MaterialPageRoute(
        builder: (_) => _TimerEditPage(
          initial: existing,
          addTitle: l10n.timerAddTitle,
          editTitle: l10n.timerEditTitle,
          labelLabel: l10n.timerFieldLabel,
          labelHint: l10n.timerFieldLabelHint,
          labelRequired: l10n.timerFieldLabelRequired,
          delayLabel: l10n.timerFieldDelay,
          delayHint: l10n.timerFieldDelayHint,
          delayInvalid: l10n.timerFieldDelayInvalid,
          promptLabel: l10n.timerFieldPrompt,
          promptHint: l10n.timerFieldPromptHint,
          actionHintLabel: l10n.timerFieldActionHint,
          actionHintHint: l10n.timerFieldActionHintHint,
          fireAtLabel: l10n.timerFieldFireAt,
          fireAtHint: l10n.timerFieldFireAtHint,
          saveLabel: l10n.commonSave,
          cancelLabel: l10n.commonCancel,
        ),
      ),
    );
    if (result == null) return;
    if (!context.mounted) return;
    final timers = context.read<TimerService>();
    if (existing == null) {
      await timers.create(
        label: result.label,
        delay: result.delay,
        fireAt: result.fireAt,
        prompt: result.prompt,
        actionHint: result.actionHint,
        source: 'user',
      );
    } else {
      // Editing a non-pending task re-creates it under the same
      // id by deleting + creating; simpler than adding a "rearm"
      // API for the user-facing path.
      if (!existing.isPending) {
        await timers.delete(existing.id);
        await timers.create(
          label: result.label,
          delay: result.delay,
          fireAt: result.fireAt,
          prompt: result.prompt,
          actionHint: result.actionHint,
          source: 'user',
        );
      } else {
        await timers.update(
          id: existing.id,
          label: result.label,
          delay: result.delay,
          fireAt: result.fireAt,
          prompt: result.prompt,
          actionHint: result.actionHint,
        );
      }
    }
    // Make sure a new timer is visible in the list (it's pending
    // so the default filter already shows it).
  }

  Future<void> _confirmCancel(BuildContext context, TimerTask t) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.timerCancelConfirmTitle),
        content: Text(l10n.timerCancelConfirmMessage(t.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await context.read<TimerService>().cancel(t.id);
  }

  Future<void> _confirmDelete(BuildContext context, TimerTask t) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.timerDeleteConfirmTitle),
        content: Text(l10n.timerDeleteConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await context.read<TimerService>().delete(t.id);
  }
}

class _TimerCard extends StatefulWidget {
  const _TimerCard({
    required this.task,
    required this.onEdit,
    required this.onCancel,
    required this.onDelete,
  });
  final TimerTask task;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  State<_TimerCard> createState() => _TimerCardState();
}

class _TimerCardState extends State<_TimerCard> {
  Timer? _tick;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    if (widget.task.isPending) _startTick();
  }

  @override
  void didUpdateWidget(covariant _TimerCard old) {
    super.didUpdateWidget(old);
    if (widget.task.isPending && _tick == null) {
      _startTick();
    } else if (!widget.task.isPending && _tick != null) {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = widget.task;
    final isPending = t.isPending;
    final delay = t.fireAt.difference(_now);
    final statusLabel = switch (t.status) {
      TimerTaskStatus.pending => l10n.timerStatusPending,
      TimerTaskStatus.fired => l10n.timerStatusFired,
      TimerTaskStatus.cancelled => l10n.timerStatusCancelled,
    };
    final statusColor = switch (t.status) {
      TimerTaskStatus.pending => AppTheme.primary,
      TimerTaskStatus.fired => Colors.green,
      TimerTaskStatus.cancelled => context.textSecondary,
    };
    final aiLabel = l10n.timerSourceAi;
    final userLabel = l10n.timerSourceUser;
    return Material(
      color: context.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: isPending ? widget.onEdit : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: context.appBorder, width: 0.6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 2, right: 10),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isPending
                      ? Icons.schedule_outlined
                      : (t.isFired
                            ? Icons.notifications_active_outlined
                            : Icons.do_not_disturb_alt_outlined),
                  size: 18,
                  color: AppTheme.primary,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isPending ? null : context.textSecondary,
                        decoration: t.isCancelled
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatSubtitle(l10n, t, delay),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    if (t.prompt.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        t.prompt,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSecondary,
                          height: 1.4,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _StatusChip(label: statusLabel, color: statusColor),
                        const SizedBox(width: 8),
                        _SourceChip(
                          source: t.source,
                          aiLabel: aiLabel,
                          userLabel: userLabel,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_horiz,
                  size: 18,
                  color: context.textSecondary,
                ),
                padding: EdgeInsets.zero,
                splashRadius: 18,
                onSelected: (v) {
                  if (v == 'edit') widget.onEdit();
                  if (v == 'cancel') widget.onCancel();
                  if (v == 'delete') widget.onDelete();
                },
                itemBuilder: (ctx) => [
                  if (isPending)
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          const Icon(Icons.edit_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text(l10n.timerActionEdit),
                        ],
                      ),
                    ),
                  if (isPending)
                    PopupMenuItem(
                      value: 'cancel',
                      child: Row(
                        children: [
                          const Icon(Icons.block_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text(l10n.timerActionCancel),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.timerActionDelete,
                          style: const TextStyle(color: Colors.redAccent),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSubtitle(AppLocalizations l10n, TimerTask t, Duration delay) {
    if (t.isPending) {
      return l10n.timerFiresIn(_humanizeDuration(delay));
    }
    if (t.isFired) {
      final fmt = _formatLocal(t.fireAt);
      return l10n.timerFiredAt(fmt);
    }
    // cancelled
    return _formatLocal(t.fireAt);
  }
}

String _humanizeDuration(Duration d) {
  if (d.isNegative) return '0s';
  if (d.inDays > 0) {
    final h = d.inHours.remainder(24);
    return h == 0 ? '${d.inDays}d' : '${d.inDays}d ${h}h';
  }
  if (d.inHours > 0) {
    final m = d.inMinutes.remainder(60);
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
  }
  if (d.inMinutes > 0) {
    final s = d.inSeconds.remainder(60);
    return s == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${s}s';
  }
  return '${d.inSeconds}s';
}

String _formatLocal(DateTime t) {
  final mm = t.month.toString().padLeft(2, '0');
  final dd = t.day.toString().padLeft(2, '0');
  final hh = t.hour.toString().padLeft(2, '0');
  final mi = t.minute.toString().padLeft(2, '0');
  final ss = t.second.toString().padLeft(2, '0');
  return '${t.year}-$mm-$dd $hh:$mi:$ss';
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.source,
    required this.aiLabel,
    required this.userLabel,
  });
  final String source;
  final String aiLabel;
  final String userLabel;

  @override
  Widget build(BuildContext context) {
    final isAi = source == 'ai';
    final color = isAi ? AppTheme.primary : Colors.blueGrey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isAi ? aiLabel : userLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _RuntimeNote extends StatelessWidget {
  const _RuntimeNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.2),
          width: 0.6,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 14, color: AppTheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                color: context.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimerEditResult {
  const _TimerEditResult({
    required this.label,
    this.delay,
    this.fireAt,
    this.prompt = '',
    this.actionHint,
  });
  final String label;
  final Duration? delay;
  final DateTime? fireAt;
  final String prompt;
  final String? actionHint;
}

class _TimerEditPage extends StatefulWidget {
  const _TimerEditPage({
    required this.initial,
    required this.addTitle,
    required this.editTitle,
    required this.labelLabel,
    required this.labelHint,
    required this.labelRequired,
    required this.delayLabel,
    required this.delayHint,
    required this.delayInvalid,
    required this.promptLabel,
    required this.promptHint,
    required this.actionHintLabel,
    required this.actionHintHint,
    required this.fireAtLabel,
    required this.fireAtHint,
    required this.saveLabel,
    required this.cancelLabel,
  });
  final TimerTask? initial;
  final String addTitle;
  final String editTitle;
  final String labelLabel;
  final String labelHint;
  final String labelRequired;
  final String delayLabel;
  final String delayHint;
  final String delayInvalid;
  final String promptLabel;
  final String promptHint;
  final String actionHintLabel;
  final String actionHintHint;
  final String fireAtLabel;
  final String fireAtHint;
  final String saveLabel;
  final String cancelLabel;

  @override
  State<_TimerEditPage> createState() => _TimerEditPageState();
}

class _TimerEditPageState extends State<_TimerEditPage> {
  late final TextEditingController _label;
  late final TextEditingController _delay;
  late final TextEditingController _prompt;
  late final TextEditingController _actionHint;
  late final TextEditingController _fireAt;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _label = TextEditingController(text: t?.label ?? '');
    _delay = TextEditingController(
      text: t == null ? '300' : t.delay.inSeconds.toString(),
    );
    _prompt = TextEditingController(text: t?.prompt ?? '');
    _actionHint = TextEditingController(text: t?.actionHint ?? '');
    _fireAt = TextEditingController(
      text: t == null ? '' : t.fireAt.toIso8601String(),
    );
  }

  @override
  void dispose() {
    _label.dispose();
    _delay.dispose();
    _prompt.dispose();
    _actionHint.dispose();
    _fireAt.dispose();
    super.dispose();
  }

  void _save() {
    final label = _label.text.trim();
    if (label.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.labelRequired)));
      return;
    }
    final delayRaw = _delay.text.trim();
    final fireAtRaw = _fireAt.text.trim();
    Duration? delay;
    DateTime? fireAt;
    if (fireAtRaw.isNotEmpty) {
      final parsed = DateTime.tryParse(fireAtRaw);
      if (parsed == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.delayInvalid)));
        return;
      }
      fireAt = parsed;
    } else if (delayRaw.isNotEmpty) {
      final parsed = int.tryParse(delayRaw);
      if (parsed == null || parsed < 0) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.delayInvalid)));
        return;
      }
      delay = Duration(seconds: parsed);
    } else {
      // No delay, no fireAt: default to 60s so the user doesn't
      // create a fire-immediately timer by accident.
      delay = const Duration(seconds: 60);
    }
    final prompt = _prompt.text.trim();
    final hint = _actionHint.text.trim();
    Navigator.of(context).pop(
      _TimerEditResult(
        label: label,
        delay: delay,
        fireAt: fireAt,
        prompt: prompt,
        actionHint: hint.isEmpty ? null : hint,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? widget.addTitle : widget.editTitle,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [TextButton(onPressed: _save, child: Text(widget.saveLabel))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Field(
              label: widget.labelLabel,
              controller: _label,
              hint: widget.labelHint,
            ),
            const SizedBox(height: 14),
            _Field(
              label: widget.delayLabel,
              controller: _delay,
              hint: widget.delayHint,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 14),
            _Field(
              label: widget.fireAtLabel,
              controller: _fireAt,
              hint: widget.fireAtHint,
            ),
            const SizedBox(height: 14),
            _Field(
              label: widget.promptLabel,
              controller: _prompt,
              hint: widget.promptHint,
              maxLines: 3,
            ),
            const SizedBox(height: 14),
            _Field(
              label: widget.actionHintLabel,
              controller: _actionHint,
              hint: widget.actionHintHint,
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
  });
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: context.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.appBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.appBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.primary, width: 1.4),
            ),
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
      ],
    );
  }
}
