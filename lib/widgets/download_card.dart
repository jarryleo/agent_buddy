import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/download.dart';
import '../providers/chat_provider.dart';
import '../theme/app_theme.dart';

/// One row in the `download` tool card. Renders the live
/// progress, status, and the Save / Open / Cancel affordances.
///
/// Driven by the [DownloadItem] snapshot on the parent
/// [ToolCall.downloads] list. The chat provider mutates that
/// list in place as bytes arrive, so this widget is just a
/// view layer — it does not own any state machine of its own.
///
/// Save flow:
///   1. user taps "Save"
///   2. widget opens a system folder picker via file_picker
///   3. on confirm, widget calls
///      [ChatProvider.saveDownload] which copies the temp file
///      to the chosen directory and flips the item to
///      [DownloadStatus.saved]
class DownloadCard extends StatelessWidget {
  const DownloadCard({
    super.key,
    required this.item,
    required this.assistantId,
    required this.toolId,
  });

  final DownloadItem item;
  final String assistantId;
  final String toolId;

  // Bytes/sizes are rendered using KB / MB. The thresholds are
  // generous: anything < 1024 bytes is just shown in B so the
  // user can see "832 B" instead of "0.8 KB".
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _statusLabel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (item.status) {
      case DownloadStatus.pending:
        return l10n.downloadStatusPending;
      case DownloadStatus.running:
        return l10n.downloadStatusRunning;
      case DownloadStatus.completed:
        return l10n.downloadStatusCompleted;
      case DownloadStatus.failed:
        return l10n.downloadStatusFailed;
      case DownloadStatus.cancelled:
        return l10n.downloadStatusCancelled;
      case DownloadStatus.saved:
        return l10n.downloadStatusSaved;
    }
  }

  Color _statusColor(BuildContext context) {
    switch (item.status) {
      case DownloadStatus.pending:
      case DownloadStatus.running:
        return AppTheme.primary;
      case DownloadStatus.completed:
      case DownloadStatus.saved:
        return const Color(0xFF1F883D);
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return const Color(0xFFD1242F);
    }
  }

  /// The progress fraction to show on the bar. Falls back to a
  /// non-null indeterminate "moving" bar when the server didn't
  /// send a Content-Length (or we have 0 bytes total).
  double? get _fraction {
    final f = item.fraction;
    if (f == null || f.isNaN || f.isInfinite) return null;
    if (item.bytesTotal <= 0) return null;
    return f.clamp(0.0, 1.0);
  }

  /// True when the local file is gone — happens after a save
  /// (we delete the temp file) or after an app restart
  /// (temp directory was wiped). Used to swap the "Save"
  /// button for an "Expired" hint in the latter case.
  bool _isExpired() {
    final p = item.localPath;
    if (p == null) return false;
    // Cheap existence check — the file might be gone after
    // app restart. Avoid running async code here; the card
    // gets rebuilt by a notifyListeners() once the consumer
    // decides the file is gone.
    return !File(p).existsSync();
  }

  Future<void> _onSaveTap(BuildContext context) async {
    final chat = context.read<ChatProvider>();
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await file_picker.FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.downloadPickFolderTitle,
      );
      if (dir == null) return;
      await chat.saveDownload(
        assistantId: assistantId,
        toolId: toolId,
        downloadId: item.id,
        destDir: dir,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.downloadSavedSnackbar(dir))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.downloadSaveFailedSnackbar(e.toString()))),
      );
    }
  }

  void _onCancelTap(BuildContext context) {
    final chat = context.read<ChatProvider>();
    chat.cancelDownload(assistantId, toolId, item.id);
  }

  Future<void> _onDiscardTap(BuildContext context) async {
    final chat = context.read<ChatProvider>();
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await chat.discardDownload(
      assistantId: assistantId,
      toolId: toolId,
      downloadId: item.id,
    );
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.downloadDiscardedSnackbar)),
    );
  }

  Future<void> _onRevealTap(BuildContext context) async {
    // Best-effort: open the system file manager at the
    // destination dir. We don't want to hard-depend on a
    // launcher package, so this is a soft attempt via
    // `Process.start` on desktop. Mobile: we just show a
    // snackbar pointing to the path.
    final p = item.savedPath;
    if (p == null) return;
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        await Process.start('open', [p]);
      } catch (_) {
        await Process.start('xdg-open', [p]);
      }
    } else if (Platform.isWindows) {
      await Process.start('explorer', [p]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color = _statusColor(context);
    final isRunning = item.status == DownloadStatus.running;
    final isFailed = item.status == DownloadStatus.failed;
    final isCompleted = item.status == DownloadStatus.completed;
    final isSaved = item.status == DownloadStatus.saved;
    final isCancelled = item.status == DownloadStatus.cancelled;

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_iconForStatus(item.status), size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.filename,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _statusLabel(context),
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SizedBox(height: 6),
          _ProgressLine(
            fraction: _fraction,
            isRunning: isRunning,
            color: color,
            indeterminateLabel: l10n.downloadProgressIndeterminate,
            bytesReceived: item.bytesReceived,
            bytesTotal: item.bytesTotal,
            format: _formatBytes,
          ),
          if (isFailed && item.error != null) ...[
            const SizedBox(height: 4),
            Text(
              item.error!,
              style: TextStyle(fontSize: 10, color: const Color(0xFFD1242F)),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (isCompleted && _isExpired()) ...[
            const SizedBox(height: 4),
            Text(
              l10n.downloadExpiredHint,
              style: TextStyle(
                fontSize: 10,
                color: context.textSecondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (isSaved && item.savedPath != null) ...[
            const SizedBox(height: 4),
            Text(
              item.savedPath!,
              style: TextStyle(
                fontSize: 10,
                color: context.textSecondary,
                fontFamily: 'monospace',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: _actionsForStatus(
              context: context,
              isRunning: isRunning,
              isFailed: isFailed,
              isCompleted: isCompleted,
              isSaved: isSaved,
              isCancelled: isCancelled,
              expired: isCompleted && _isExpired(),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _actionsForStatus({
    required BuildContext context,
    required bool isRunning,
    required bool isFailed,
    required bool isCompleted,
    required bool isSaved,
    required bool isCancelled,
    required bool expired,
  }) {
    final l10n = AppLocalizations.of(context);
    final compact = TextStyle(fontSize: 11);
    final buttons = <Widget>[];
    if (isRunning) {
      buttons.add(
        TextButton(
          onPressed: () => _onCancelTap(context),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(l10n.downloadActionCancel, style: compact),
        ),
      );
    } else if (isFailed || isCancelled) {
      buttons.add(
        TextButton(
          onPressed: () => _onDiscardTap(context),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(l10n.downloadActionDiscard, style: compact),
        ),
      );
    } else if (isCompleted && !expired) {
      buttons.add(
        FilledButton.icon(
          onPressed: () => _onSaveTap(context),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: compact,
          ),
          icon: const Icon(Icons.save_alt_rounded, size: 12),
          label: Text(l10n.downloadActionSave),
        ),
      );
      buttons.add(const SizedBox(width: 4));
      buttons.add(
        TextButton(
          onPressed: () => _onDiscardTap(context),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(l10n.downloadActionDiscard, style: compact),
        ),
      );
    } else if (isSaved) {
      buttons.add(
        TextButton.icon(
          onPressed: () => _onRevealTap(context),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: compact,
          ),
          icon: const Icon(Icons.folder_open_rounded, size: 12),
          label: Text(l10n.downloadActionReveal),
        ),
      );
    }
    return buttons;
  }

  IconData _iconForStatus(DownloadStatus s) {
    switch (s) {
      case DownloadStatus.pending:
        return Icons.schedule_outlined;
      case DownloadStatus.running:
        return Icons.hourglass_top_rounded;
      case DownloadStatus.completed:
        return Icons.check_circle_outline_rounded;
      case DownloadStatus.failed:
        return Icons.error_outline_rounded;
      case DownloadStatus.cancelled:
        return Icons.cancel_outlined;
      case DownloadStatus.saved:
        return Icons.task_alt_rounded;
    }
  }
}

/// Renders a single line under the file name: a LinearProgressIndicator
/// on the left, plus a "{received} / {total}" caption on the right.
/// When the server didn't send a Content-Length, the bar goes
/// indeterminate and the caption collapses to just "Downloading…".
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({
    required this.fraction,
    required this.isRunning,
    required this.color,
    required this.indeterminateLabel,
    required this.bytesReceived,
    required this.bytesTotal,
    required this.format,
  });

  final double? fraction;
  final bool isRunning;
  final Color color;
  final String indeterminateLabel;
  final int bytesReceived;
  final int bytesTotal;
  final String Function(int) format;

  @override
  Widget build(BuildContext context) {
    final indeterminate = fraction == null;
    final caption = indeterminate
        ? indeterminateLabel
        : '${format(bytesReceived)} / ${format(bytesTotal)}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: indeterminate
                  ? LinearProgressIndicator(
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.15),
                    )
                  : LinearProgressIndicator(
                      value: fraction,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.15),
                    ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: Text(
            caption,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 10,
              color: context.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
