import 'dart:io';

import 'package:file_picker/file_picker.dart' as file_picker;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/edited_image.dart';
import '../providers/chat_provider.dart';
import '../theme/app_theme.dart';
import 'image_preview.dart';

/// One preview tile for the `edit_image` tool. Shows the
/// processed image with a compact metadata caption
/// ("compress · 800×600 · 412 KB") and a download button at
/// the bottom-right corner.
///
/// The widget is intentionally stateless and reads its data
/// from a parent-supplied [EditedImage]; the chat provider
/// owns the persistence. Save affordance mirrors the
/// `DownloadCard` flow — system folder picker, then copy.
class EditImageCard extends StatelessWidget {
  const EditImageCard({
    super.key,
    required this.image,
    required this.assistantId,
    required this.toolId,
  });

  final EditedImage image;
  final String assistantId;
  final String toolId;

  /// `true` when the on-disk temp file is gone. Mirrors
  /// `DownloadCard._isExpired()` — happens after an app
  /// restart (OS wipes the temp dir) or after the user has
  /// cleaned up temp files manually.
  bool get _isExpired {
    final p = image.path;
    if (p.isEmpty) return true;
    return !File(p).existsSync();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  }

  /// Localized action label for the action that produced
  /// this image.
  String _actionLabel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (image.action) {
      case 'compress':
        return l10n.editImageActionCompress;
      case 'crop':
        return l10n.editImageActionCrop;
      case 'resize':
        return l10n.editImageActionResize;
      case 'rotate':
        return l10n.editImageActionRotate;
      default:
        return image.action;
    }
  }

  /// "+" / "−" suffix that goes after the byte count when we
  /// have a baseline to compare against. `null` when the
  /// caller didn't supply `sourceSize` (or the baseline is
  /// zero / missing).
  String? _deltaCaption(BuildContext context) {
    final delta = image.sizeDeltaPercent;
    if (delta == null) return null;
    final l10n = AppLocalizations.of(context);
    final rounded = delta.toStringAsFixed(0);
    if (delta < 0) {
      return l10n.editImageDeltaSaved(rounded.replaceAll('-', ''));
    }
    if (delta > 0) {
      return l10n.editImageDeltaGrew(rounded);
    }
    return null;
  }

  Future<void> _onSaveTap(BuildContext context) async {
    final chat = context.read<ChatProvider>();
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await file_picker.FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.editImagePickFolderTitle,
      );
      if (dir == null) return;
      final savedPath = await chat.saveEditedImage(
        assistantId: assistantId,
        toolId: toolId,
        imagePath: image.path,
        destDir: dir,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.editImageSavedSnackbar(savedPath))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.editImageSaveFailedSnackbar(e.toString())),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final expired = _isExpired;
    final delta = _deltaCaption(context);
    // "compress · 800×600 · 412 KB (-52%)" — concatenated with
    // mid-dots. Short enough to fit one line on a phone-width
    // bubble without truncation on the common cases.
    final parts = <String>[
      _actionLabel(context),
      '${image.width}×${image.height}',
      _formatBytes(image.size),
      ?delta,
    ];
    final caption = parts.join(' · ');

    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Preview area. We use a fixed aspect ratio (4:3)
          // so the bubble's overall height stays predictable
          // for short edited images, and a square thumb would
          // either crop or letterbox awkwardly. The actual
          // image's aspect ratio is preserved inside the box
          // (BoxFit.contain) — the box just gets a uniform
          // shape so multiple cards in the same bubble align.
          AspectRatio(
            aspectRatio: 4 / 3,
            child: GestureDetector(
              onTap: expired
                  ? null
                  : () =>
                        ImagePreviewPage.showLocal(context, image.path),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                    child: expired
                        ? Container(
                            color: context.bg,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.broken_image_outlined,
                                  color: context.textSecondary,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  l10n.editImageExpired,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: context.textSecondary,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Image.file(
                            File(image.path),
                            fit: BoxFit.contain,
                            // Reasonable cap on the decode
                            // resolution for the inline preview
                            // — full resolution is reserved for
                            // the tap-to-preview overlay.
                            cacheWidth: 1200,
                            errorBuilder: (context, error, stack) => Container(
                              color: context.bg,
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: context.textSecondary,
                              ),
                            ),
                          ),
                  ),
                  // Download button — overlays the
                  // bottom-right corner of the preview so the
                  // affordance is unmissable. Mirrors the
                  // TTS speaker pattern in `MessageBubble`.
                  if (!expired)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: _DownloadButton(onTap: () => _onSaveTap(context)),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
            child: Text(
              caption,
              style: TextStyle(
                fontSize: 11,
                color: context.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small circular icon button with a download glyph. Visually
/// matches the rest of the bubble's "overlay corner" affordances
/// (TTS speaker, copy icon) — 28×28 pill, 50%-opaque surface
/// so the button reads as a tappable overlay without hiding the
/// preview underneath.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label: l10n.editImageActionSave,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: context.bubbleAssistant.withValues(alpha: 0.7),
            shape: BoxShape.circle,
            border: Border.all(color: context.appBorder, width: 0.5),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.download_rounded,
            size: 16,
            color: context.textPrimary,
          ),
        ),
      ),
    );
  }
}