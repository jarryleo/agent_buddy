import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/image_service.dart';
import '../theme/app_theme.dart';
import 'image_preview.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.onSend,
    required this.enabled,
    required this.imageService,
  });

  final void Function(String text, List<String> imagePaths) onSend;
  final bool enabled;
  final ImageService imageService;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<String> _imagePaths = [];
  static const int _maxLinesCollapsed = 1;
  static const int _maxLinesExpanded = 10;
  bool _pickingImage = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if ((text.isEmpty && _imagePaths.isEmpty) || !widget.enabled) return;
    widget.onSend(text, List.of(_imagePaths));
    _controller.clear();
    setState(() => _imagePaths.clear());
  }

  Future<void> _pickImage() async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    try {
      final l10n = AppLocalizations.of(context);
      final source = await showModalBottomSheet<ImageSourceChoice>(
        context: context,
        backgroundColor: AppTheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(l10n.imagePickGallery),
                onTap: () => Navigator.pop(ctx, ImageSourceChoice.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: Text(l10n.imagePickCamera),
                onTap: () => Navigator.pop(ctx, ImageSourceChoice.camera),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: Text(l10n.commonCancel),
                onTap: () => Navigator.pop(ctx, null),
              ),
            ],
          ),
        ),
      );
      if (source == null) return;
      final path = source == ImageSourceChoice.gallery
          ? await widget.imageService.pickFromGallery()
          : await widget.imageService.pickFromCamera();
      if (path == null) return;
      if (!mounted) return;
      setState(() => _imagePaths.add(path));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasImages = _imagePaths.isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.border)),
      ),
      padding: EdgeInsets.fromLTRB(
        10,
        8,
        10,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasImages) _buildThumbnails(l10n),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: widget.enabled && !_pickingImage
                        ? _pickImage
                        : null,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    color: AppTheme.textSecondary,
                    tooltip: l10n.imageAttachTooltip,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 40,
                      maxHeight: 40 * _maxLinesExpanded + 24,
                    ),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: widget.enabled,
                      minLines: _maxLinesCollapsed,
                      maxLines: _maxLinesExpanded,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(fontSize: 15, height: 1.4),
                      decoration: InputDecoration(
                        hintText: widget.enabled
                            ? l10n.chatInputHint
                            : l10n.chatInputHintNoModel,
                        hintStyle: const TextStyle(
                          color: AppTheme.textSecondary,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: const BorderSide(color: AppTheme.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: const BorderSide(color: AppTheme.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: const BorderSide(
                            color: AppTheme.primary,
                            width: 1.2,
                          ),
                        ),
                        isDense: true,
                      ),
                      onSubmitted: widget.enabled ? (_) => _send() : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 40,
                  child: ElevatedButton(
                    onPressed: widget.enabled ? _send : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      disabledBackgroundColor: AppTheme.primary.withValues(
                        alpha: 0.4,
                      ),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      elevation: 0,
                    ),
                    child: const Icon(Icons.send_rounded, size: 18),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnails(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _imagePaths.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            final path = _imagePaths[index];
            return _ImageThumbnail(
              path: path,
              onRemove: () => setState(() => _imagePaths.removeAt(index)),
              onTap: () => ImagePreviewPage.showLocal(context, path),
              removeTooltip: l10n.imageRemoveTooltip,
            );
          },
        ),
      ),
    );
  }
}

enum ImageSourceChoice { gallery, camera }

class _ImageThumbnail extends StatelessWidget {
  const _ImageThumbnail({
    required this.path,
    required this.onRemove,
    required this.onTap,
    required this.removeTooltip,
  });

  final String path;
  final VoidCallback onRemove;
  final VoidCallback onTap;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: onTap,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Container(
                    color: AppTheme.bg,
                    child: const Icon(
                      Icons.broken_image_outlined,
                      color: AppTheme.textSecondary,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
