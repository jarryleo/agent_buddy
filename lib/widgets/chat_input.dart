import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/file_attachment.dart';
import '../services/file_attachment_service.dart';
import '../services/image_service.dart';
import '../theme/app_theme.dart';
import 'image_preview.dart';

class ChatInput extends StatefulWidget {
  const ChatInput({
    super.key,
    required this.onSend,
    required this.enabled,
    required this.imageService,
    required this.fileAttachmentService,
    this.workingDirectory,
    this.thinkingEnabled = false,
    this.onWorkingDirectoryChanged,
    this.onThinkingChanged,
    this.sending = false,
    this.onStop,
  });

  final void Function(
    String text,
    List<String> imagePaths,
    List<ChatFileAttachment> fileAttachments,
  )
  onSend;
  final bool enabled;
  final bool sending;
  final VoidCallback? onStop;
  final ImageService imageService;
  final FileAttachmentService fileAttachmentService;
  final String? workingDirectory;
  final bool thinkingEnabled;

  /// Set / clear the user-selected working directory. The
  /// `(path, treeUri)` shape is platform-conditional:
  ///   * **Android** — `path` is the display path the
  ///     user picked via SAF (e.g. `/storage/emulated/0/Download/test`);
  ///     `treeUri` is the `content://` tree URI the native
  ///     side persists to back the SAF grant. **Both are
  ///     required** for the model to actually write into
  ///     the folder (the native `FileBridge` is the
  ///     authority on the tree URI and mirrors it to its own
  ///     SharedPreferences, so the caller only needs to
  ///     surface it to `SettingsProvider`).
  ///   * **iOS / desktop** — only `path` is meaningful;
  ///     `treeUri` is `null` (iOS uses the app sandbox, so
  ///     `dart:io` is enough; desktop doesn't gate paths).
  /// Pass `path: null` to clear the working directory
  /// (which also drops the tree URI on Android).
  final Future<void> Function({String? path, String? treeUri})?
  onWorkingDirectoryChanged;
  final Future<void> Function(bool enabled)? onThinkingChanged;

  @override
  State<ChatInput> createState() => _ChatInputState();
}

const int _kMaxLinesCollapsed = 1;
const int _kMaxLinesExpanded = 10;

/// Thrown when the SAF `pickTree` channel is missing — i.e.
/// the user is somehow on a build that has no Android
/// `FileBridge` (desktop / iOS / web). Surfaced as a
/// user-facing snackbar via the catch in [_pickWorkingDirectory].
class _SafNotAvailable implements Exception {
  const _SafNotAvailable();
  @override
  String toString() => 'SAF tree picker is not available on this platform';
}

class _ChatInputState extends State<ChatInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<String> _imagePaths = [];
  final List<ChatFileAttachment> _fileAttachments = [];
  bool _pickingImage = false;
  bool _pickingFile = false;
  bool _toolbarOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if ((text.isEmpty && _imagePaths.isEmpty && _fileAttachments.isEmpty) ||
        !widget.enabled) {
      return;
    }
    _setToolbarOpen(false);
    widget.onSend(
      text,
      List.unmodifiable(_imagePaths),
      List.unmodifiable(_fileAttachments),
    );
    _controller.clear();
    setState(() {
      _imagePaths.clear();
      _fileAttachments.clear();
    });
  }

  void _toggleToolbar() => _setToolbarOpen(!_toolbarOpen);

  void _setToolbarOpen(bool open) {
    if (_toolbarOpen == open) return;
    setState(() {
      _toolbarOpen = open;
      if (open) _focusNode.unfocus();
    });
  }

  Widget _buildToolbar(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, thickness: 0.5, color: context.appBorder),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _toolbarAction(
                context: context,
                icon: Icons.image_outlined,
                label: l10n.chatToolImage,
                onTap: widget.enabled ? _pickImage : null,
              ),
              _toolbarAction(
                context: context,
                icon: Icons.attach_file_rounded,
                label: l10n.chatToolFile,
                onTap: widget.enabled ? _pickFile : null,
              ),
              _toolbarAction(
                context: context,
                icon: Icons.folder_outlined,
                label: l10n.chatToolWorkingDirectory,
                active: widget.workingDirectory?.isNotEmpty == true,
                tooltip: widget.workingDirectory,
                onTap: widget.sending ? null : _pickWorkingDirectory,
              ),
              Expanded(child: _thinkingToggle(context, l10n)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _thinkingToggle(BuildContext context, AppLocalizations l10n) {
    final enabled = !widget.sending;
    final color = enabled
        ? context.textPrimary
        : context.textSecondary.withValues(alpha: 0.5);
    return Semantics(
      button: true,
      label: l10n.chatToolThinking,
      child: InkWell(
        key: const ValueKey('chat-thinking-toggle'),
        onTap: enabled ? _toggleThinking : null,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 24,
                child: FittedBox(
                  fit: BoxFit.fitHeight,
                  child: Switch.adaptive(
                    value: widget.thinkingEnabled,
                    onChanged: enabled ? _setThinkingMode : null,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l10n.chatToolThinking,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarAction({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool active = false,
    String? tooltip,
  }) {
    final color = onTap == null
        ? context.textSecondary.withValues(alpha: 0.5)
        : active
        ? AppTheme.primary
        : context.textSecondary;
    return Expanded(
      child: Tooltip(
        message: tooltip ?? label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: onTap == null ? color : context.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickFile() async {
    if (_pickingFile) return;
    _setToolbarOpen(false);
    setState(() => _pickingFile = true);
    try {
      final files = await widget.fileAttachmentService.pickFiles();
      if (!mounted || files.isEmpty) return;
      setState(() => _fileAttachments.addAll(files));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).fileErrorFailedToAttach(e.toString()),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  Future<void> _pickWorkingDirectory() async {
    _setToolbarOpen(false);
    final l10n = AppLocalizations.of(context);
    try {
      if (!kIsWeb && Platform.isAndroid) {
        // Android: route through the native SAF tree picker so
        // we get a `content://` tree URI grant (the only way
        // the model can actually write into a public volume
        // like `/storage/emulated/0/...`). The picker is
        // parked by the native bridge; we just await the
        // future the FileService exposes.
        final result = await _safPickWorkingDirectory();
        if (result == null) return; // user cancelled
        await widget.onWorkingDirectoryChanged?.call(
          path: result.path,
          treeUri: result.treeUri,
        );
        return;
      }
      // iOS / desktop: a plain directory path is enough —
      // iOS uses the app sandbox, desktop doesn't gate
      // paths, and `dart:io` works without any SAF grant.
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.chatToolWorkingDirectory,
      );
      if (path == null || !mounted) return;
      await widget.onWorkingDirectoryChanged?.call(path: path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.workingDirectoryError(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Wraps the native `pickTree` MethodChannel call. Kept
  /// separate from `_pickWorkingDirectory` so we don't drag
  /// `MethodChannel` + `dart:io` into the rest of the widget.
  /// On non-Android platforms the call falls through to the
  /// `FilePicker` path above.
  Future<({String path, String treeUri})?> _safPickWorkingDirectory() async {
    const channel = MethodChannel('agent_buddy/file');
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>(
        'pickTree',
        const <String, dynamic>{},
      );
      if (raw == null) return null;
      if (raw['cancelled'] == true) return null;
      final path = raw['path'] as String?;
      final treeUri = raw['tree_uri'] as String?;
      if (path == null || path.isEmpty || treeUri == null || treeUri.isEmpty) {
        throw StateError(
          'pickTree returned a payload without path / tree_uri: $raw',
        );
      }
      return (path: path, treeUri: treeUri);
    } on PlatformException catch (e) {
      throw Exception('pickTree failed: ${e.code}: ${e.message}');
    } on MissingPluginException {
      throw const _SafNotAvailable();
    }
  }

  void _toggleThinking() {
    _setThinkingMode(!widget.thinkingEnabled);
  }

  Future<void> _setThinkingMode(bool enabled) async {
    await widget.onThinkingChanged?.call(enabled);
  }

  Future<void> _pickImage() async {
    if (_pickingImage) return;
    _setToolbarOpen(false);
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

  void _handlePaste() async {
    var pastedFileCount = 0;
    try {
      final paths = await _readFileDropList();
      if (paths.isNotEmpty) {
        final imagePaths = paths.where(_isImageFile).toList();
        final filePaths = paths.where((path) => !_isImageFile(path));
        final files = await widget.fileAttachmentService.importPaths(filePaths);
        if (mounted) {
          setState(() {
            _imagePaths.addAll(imagePaths);
            _fileAttachments.addAll(files);
          });
        }
        pastedFileCount = paths.length;
      }
    } catch (_) {}

    if (pastedFileCount == 0) {
      try {
        final imageBytes = await _readClipboardImage();
        if (imageBytes != null && imageBytes.isNotEmpty) {
          final path = await _savePastedImage(imageBytes);
          if (mounted) setState(() => _imagePaths.add(path));
          return;
        }
      } catch (_) {}

      try {
        final textData = await Clipboard.getData(Clipboard.kTextPlain);
        if (textData?.text != null && textData!.text!.isNotEmpty) {
          final text = textData.text!;
          if (_tryAddImageFile(text)) return;
          _insertText(text);
        }
      } catch (_) {}
    }
  }

  /// Read the clipboard file drop list (copied files from Explorer etc.)
  /// via platform-specific tooling. Returns empty list on failure.
  Future<List<String>> _readFileDropList() async {
    if (!Platform.isWindows) return [];
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Add-Type -AssemblyName System.Windows.Forms; '
          '\$files = [System.Windows.Forms.Clipboard]::GetFileDropList(); '
          'if (\$files -ne \$null -and \$files.Count -gt 0) { '
          'foreach (\$f in \$files) { Write-Output \$f } '
          '} else { Write-Output \'\' }',
    ], runInShell: true);
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
        final psResult = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms; '
              '\$img = [System.Windows.Forms.Clipboard]::GetImage(); '
              'if (\$img -ne \$null) { '
              '\$img.Save(\'$tempFile\', [System.Drawing.Imaging.ImageFormat]::Png); '
              'Write-Output \'OK\' '
              '} else { Write-Output \'null\' }',
        ], runInShell: true);
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

  /// If [text] is a path to an existing image file, add it and return true.
  bool _tryAddImageFile(String text) {
    final trimmed = text.trim();
    try {
      if (File(trimmed).existsSync() && _isImageFile(trimmed)) {
        setState(() => _imagePaths.add(trimmed));
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
    final offset = selection.isValid
        ? selection.start
        : _controller.text.length;
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
    final hasAttachments =
        _imagePaths.isNotEmpty || _fileAttachments.isNotEmpty;
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
                    onPressed:
                        !widget.sending && !_pickingImage && !_pickingFile
                        ? _toggleToolbar
                        : null,
                    icon: TweenAnimationBuilder<double>(
                      duration: const Duration(milliseconds: 500),
                      tween: Tween(begin: 0.0, end: _toolbarOpen ? 0.125 : 0.0),
                      curve: Curves.easeInOutCubic,
                      builder: (context, value, child) => Transform.rotate(
                        angle: value * 2 * math.pi,
                        child: child,
                      ),
                      child: Icon(Icons.add, color: context.textSecondary),
                    ),
                    color: context.textSecondary,
                    tooltip: l10n.chatToolsTooltip,
                  ),
                ),
                const SizedBox(width: 6),
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
                            disabledBackgroundColor: AppTheme.primary
                                .withValues(alpha: 0.4),
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
            ClipRect(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _toolbarOpen
                    ? _buildToolbar(context)
                    : const SizedBox.shrink(),
              ),
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
          itemCount: _imagePaths.length + _fileAttachments.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, index) {
            if (index < _imagePaths.length) {
              final path = _imagePaths[index];
              return _AttachmentThumbnail(
                path: path,
                name: p.basename(path),
                isImage: true,
                onRemove: () => setState(() => _imagePaths.removeAt(index)),
                onTap: () => ImagePreviewPage.showLocal(context, path),
                removeTooltip: l10n.imageRemoveTooltip,
              );
            }
            final fileIndex = index - _imagePaths.length;
            final file = _fileAttachments[fileIndex];
            return _AttachmentThumbnail(
              path: file.path,
              name: file.name,
              isImage: false,
              onRemove: () =>
                  setState(() => _fileAttachments.removeAt(fileIndex)),
              onTap: null,
              removeTooltip: l10n.fileRemoveTooltip,
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
    required this.name,
    required this.isImage,
    required this.onRemove,
    required this.onTap,
    required this.removeTooltip,
  });

  final String path;
  final String name;
  final bool isImage;
  final VoidCallback onRemove;
  final VoidCallback? onTap;
  final String removeTooltip;

  @override
  Widget build(BuildContext context) {
    // Decode the attachment thumbnail at the device pixel footprint
    // (64dp * dpr) instead of the full-resolution photo. Without this a
    // 4k photo costs ~30MB of texture memory for a 64dp chip and looks
    // washed-out on hi-dpi screens.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (64 * dpr).round();
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
                        filterQuality: FilterQuality.high,
                        cacheWidth: cacheSize,
                        cacheHeight: cacheSize,
                        errorBuilder: (context, error, stack) =>
                            _fileIcon(context, name),
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
