import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
    this.sending = false,
    this.onStop,
  });

  final void Function(String text, List<String> imagePaths) onSend;
  final bool enabled;
  final bool sending;
  final VoidCallback? onStop;
  final ImageService imageService;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

const int _kMaxLinesCollapsed = 1;
const int _kMaxLinesExpanded = 10;

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<String> _attachmentPaths = [];
  bool _pickingImage = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if ((text.isEmpty && _attachmentPaths.isEmpty) || !widget.enabled) return;

    // Separate images (sent as multimodal content) from other files.
    final images = <String>[];
    final nonImageText = <String>[];
    for (final p in _attachmentPaths) {
      if (_isImageFile(p)) {
        images.add(p);
      } else {
        nonImageText.add(p);
      }
    }

    final finalText = nonImageText.isEmpty
        ? text
        : text.isNotEmpty
            ? '$text\n---\n${nonImageText.join('\n')}'
            : nonImageText.join('\n');

    widget.onSend(finalText, images);
    _controller.clear();
    setState(() => _attachmentPaths.clear());
  }

  Future<void> _pickImage() async {
    if (_pickingImage) return;
    setState(() => _pickingImage = true);
    try {
      final l10n = AppLocalizations.of(context);
      final source = await showModalBottomSheet<ImageSourceChoice>(
        context: context,
        backgroundColor: context.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.photo_library_outlined),
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
      setState(() => _attachmentPaths.add(path));
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

  /// Handle paste (Ctrl+V / Cmd+V): read clipboard for files, images,
  /// and text. All files go to [_attachmentPaths] (thumbnail strip).
  /// Images are sent as multimodal content; non-image file paths are
  /// appended to the message text on send so the AI can reference them.
  void _handlePaste() async {
    // 1. File drop list (copied files from Explorer / Finder).
    var pastedFileCount = 0;
    try {
      final files = await _readFileDropList();
      if (files.isNotEmpty) {
        setState(() => _attachmentPaths.addAll(files));
        pastedFileCount = files.length;
      }
    } catch (_) {
      // File drop list read is best-effort.
    }

    // 2. Image paste — only when no files were found above, so
    //    a copied screenshot doesn't also get inserted as text.
    if (pastedFileCount == 0) {
      try {
        final imageBytes = await _readClipboardImage();
        if (imageBytes != null && imageBytes.isNotEmpty) {
          final path = await _savePastedImage(imageBytes);
          if (mounted) setState(() => _attachmentPaths.add(path));
          return; // Screenshot takes priority over any stray text.
        }
      } catch (_) {
        // Image paste is best-effort.
      }

      // 3. Plain text paste — fallback when no files or images.
      try {
        final textData = await Clipboard.getData(Clipboard.kTextPlain);
        if (textData?.text != null && textData!.text!.isNotEmpty) {
          final text = textData.text!;
          if (_tryAddImageFile(text)) return;
          _insertText(text);
        }
      } catch (_) {
        // Ignore clipboard read failures.
      }
    }
  }

  /// Read the clipboard file drop list (copied files from Explorer etc.)
  /// via platform-specific tooling. Returns empty list on failure.
  Future<List<String>> _readFileDropList() async {
    if (!Platform.isWindows) return [];
    final result = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; '
            '\$files = [System.Windows.Forms.Clipboard]::GetFileDropList(); '
            'if (\$files -ne \$null -and \$files.Count -gt 0) { '
            'foreach (\$f in \$files) { Write-Output \$f } '
            '} else { Write-Output \'\' }',
      ],
      runInShell: true,
    );
    if (result.exitCode != 0) return [];
    return (result.stdout as String)
        .split('\r\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// Try to read clipboard image bytes in a platform-specific way.
  /// Returns `null` when no image is available or reading is unsupported.
  Future<Uint8List?> _readClipboardImage() async {
    if (Platform.isWindows) {
      final tempDir = Directory.systemTemp;
      final tempFile = p.join(
        tempDir.path,
        'ab_clip_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      try {
        final psResult = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-Command',
            'Add-Type -AssemblyName System.Windows.Forms; '
                '\$img = [System.Windows.Forms.Clipboard]::GetImage(); '
                'if (\$img -ne \$null) { '
                '\$img.Save(\'$tempFile\', [System.Drawing.Imaging.ImageFormat]::Png); '
                'Write-Output \'OK\' '
                '} else { Write-Output \'null\' }',
          ],
          runInShell: true,
        );
        if (psResult.exitCode == 0 &&
            psResult.stdout.toString().trim() == 'OK') {
          final file = File(tempFile);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            await file.delete();
            return bytes;
          }
        }
      } finally {
        final temp = File(tempFile);
        if (await temp.exists()) await temp.delete();
      }
    }
    // TODO: macOS → `osascript` / `pngpaste`, Linux → `xclip` / `wl-paste`.
    return null;
  }

  static bool _isImageFile(String path) {
    final ext = p.extension(path).toLowerCase();
    return ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'].contains(ext);
  }

  /// If [text] is a path to an existing image file, add it to
  /// [_attachmentPaths] and return true. Otherwise return false.
  bool _tryAddImageFile(String text) {
    final trimmed = text.trim();
    try {
      if (File(trimmed).existsSync() && _isImageFile(trimmed)) {
        setState(() => _attachmentPaths.add(trimmed));
        return true;
      }
    } catch (_) {
      // Not a valid file path.
    }
    return false;
  }

  /// Persist clipboard image bytes to `{docDir}/chat_images/paste_*.png`.
  Future<String> _savePastedImage(Uint8List bytes) async {
    final baseDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(baseDir.path, 'chat_images'));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final destPath = p.join(
      imagesDir.path,
      'paste_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await File(destPath).writeAsBytes(bytes);
    return destPath;
  }

  /// Insert [text] into the controller at the current cursor / selection,
  /// replacing any selected text.
  void _insertText(String text) {
    final selection = _controller.selection;
    final offset = selection.isValid ? selection.start : _controller.text.length;
    final end = selection.isValid && selection.start != selection.end
        ? selection.end
        : offset;
    final newText = _controller.text.replaceRange(offset, end, text);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset + text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasAttachments = _attachmentPaths.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.appBorder)),
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
            if (hasAttachments) _buildThumbnails(l10n),
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
                    icon: Icon(Icons.add_photo_alternate_outlined),
                    color: context.textSecondary,
                    tooltip: l10n.imageAttachTooltip,
                  ),
                ),
                SizedBox(width: 6),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 40,
                      maxHeight: 40 * _kMaxLinesExpanded + 24,
                    ),
                    child: _InputField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: widget.enabled,
                      sending: widget.sending,
                      onSubmit: _send,
                      onPaste: _handlePaste,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 40,
                  child: widget.sending
                      ? ElevatedButton(
                          onPressed: widget.onStop,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            elevation: 0,
                          ),
                          child: const Icon(Icons.stop_rounded, size: 18),
                        )
                      : ElevatedButton(
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
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
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
        height: 78,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _attachmentPaths.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            final path = _attachmentPaths[index];
            final isImage = _isImageFile(path);
            return _AttachmentThumbnail(
              path: path,
              isImage: isImage,
              onRemove: () => setState(() => _attachmentPaths.removeAt(index)),
              onTap: isImage
                  ? () => ImagePreviewPage.showLocal(context, path)
                  : null,
              removeTooltip: l10n.imageRemoveTooltip,
            );
          },
        ),
      ),
    );
  }
}

enum ImageSourceChoice { gallery, camera }

/// Scrolling marquee text for long filenames. Scrolls horizontally
/// when the text is wider than the available width, then pauses and
/// scrolls back.
class _ScrollingFileName extends StatefulWidget {
  const _ScrollingFileName({required this.text});
  final String text;

  @override
  State<_ScrollingFileName> createState() => _ScrollingFileNameState();
}

class _ScrollingFileNameState extends State<_ScrollingFileName> {
  final ScrollController _ctrl = ScrollController();
  bool _overflow = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScrollEnd);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAndLoop());
  }

  void _onScrollEnd() {
    if (!_overflow || !_ctrl.hasClients) return;
    // When user manually scrolls, restart after a pause.
  }

  Future<void> _checkAndLoop() async {
    if (!mounted || !_ctrl.hasClients) return;
    final overflow = _ctrl.position.maxScrollExtent > 0;
    if (overflow != _overflow) setState(() => _overflow = overflow);
    if (!_overflow) return;

    while (mounted && _overflow) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) break;
      await _ctrl.animateTo(
        _ctrl.position.maxScrollExtent,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      );
      if (!mounted) break;
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) break;
      await _ctrl.animateTo(
        0,
        duration: const Duration(seconds: 2),
        curve: Curves.linear,
      );
    }
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onScrollEnd);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      controller: _ctrl,
      child: Text(
        widget.text,
        style: TextStyle(fontSize: 9, color: context.textSecondary),
        maxLines: 1,
      ),
    );
  }
}

/// Multi-line chat input with platform-aware Enter behavior:
///
///   - **Desktop** (macOS / Windows / Linux): plain Enter sends.
///     Ctrl+Enter / Cmd+Enter / Alt+Enter insert a newline. We
///     detect the modifier key in a [Focus.onKeyEvent] handler
///     and intercept Enter only when no modifier is pressed.
///   - **Mobile / web**: plain Enter inserts a newline (the OS
///     keyboard never sends a "submit" keystroke here, so the
///     Focus handler is a no-op and Enter naturally falls through
///     to the IME's newline behavior). The user has to tap the
///     send button.
class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.sending,
    required this.onSubmit,
    this.onPaste,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool sending;
  final VoidCallback onSubmit;
  final VoidCallback? onPaste;

  bool get _isDesktop {
    if (kIsWeb) return true;
    return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_isDesktop) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // Intercept Ctrl+V / Cmd+V to handle image paste alongside text.
    if (key == LogicalKeyboardKey.keyV) {
      final isPasteModifier =
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      if (isPasteModifier && onPaste != null) {
        onPaste!();
        return KeyEventResult.handled;
      }
      if (isPasteModifier) return KeyEventResult.handled;
    }

    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final isModifierPressed =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed;
    if (isModifierPressed) {
      // Let the modifier+Enter combo fall through to the default
      // newline behavior.
      return KeyEventResult.ignored;
    }
    if (!enabled) return KeyEventResult.ignored;
    onSubmit();
    return KeyEventResult.handled;
  }

  /// The input box's hint text depends on three states: ready
  /// to send, currently replying (model in flight), or no
  /// model configured. The last one was previously conflated
  /// with the second — the widget would say "please add a
  /// model" while the model was actively replying — which is
  /// the user-visible bug we're fixing. The replying hint
  /// already existed in l10n; it just wasn't wired up.
  String _hintText(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (!enabled && sending) return l10n.chatInputHintReplying;
    if (!enabled) return l10n.chatInputHintNoModel;
    return l10n.chatInputHint;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        minLines: _kMaxLinesCollapsed,
        maxLines: _kMaxLinesExpanded,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
        style: const TextStyle(fontSize: 15, height: 1.4),
        decoration: InputDecoration(
          hintText: _hintText(context),
          hintStyle: TextStyle(color: context.textSecondary),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: context.appBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: context.appBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: const BorderSide(color: AppTheme.primary, width: 1.2),
          ),
          isDense: true,
        ),
      ),
    );
  }
}

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({
    required this.path,
    required this.isImage,
    required this.onRemove,
    required this.onTap,
    required this.removeTooltip,
  });

  final String path;
  final bool isImage;
  final VoidCallback onRemove;
  final VoidCallback? onTap;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    final name = p.basename(path);
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: isImage
                  ? GestureDetector(
                      onTap: onTap,
                      child: Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stack) => _fileIcon(context, name),
                      ),
                    )
                  : _fileIcon(context, name),
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

  static Widget _fileIcon(BuildContext context, String name) {
    return Container(
      color: context.bg,
      child: Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 20,
                  color: context.textSecondary,
                ),
                const SizedBox(height: 1),
                Text(
                  _shortExtension(name),
                  style: TextStyle(fontSize: 8, color: context.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            height: 14,
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: _ScrollingFileName(text: name),
          ),
        ],
      ),
    );
  }

  static String _shortExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot == -1 || dot == name.length - 1) return '?';
    return name.substring(dot + 1).toUpperCase();
  }
}
