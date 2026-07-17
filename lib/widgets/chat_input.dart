import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/file_attachment.dart';
import '../services/file_attachment_service.dart';
import '../services/image_service.dart';
import '../services/platform/calendar_service.dart'
    show PlatformPermissionStatus;
import '../services/platform/voice_service.dart';
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
    required this.voiceService,
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
  final VoiceService voiceService;
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

  // Voice input state.
  bool _voiceListening = false;
  double _voiceLevel = 0.0;
  String _voicePartial = '';
  // Listenable view of [_voiceLevel], consumed by [_InputField] so
  // the input's volume-monitor background can repaint on every level
  // tick without rebuilding the whole chat input column.
  final ValueNotifier<double> _voiceLevelNotifier = ValueNotifier<double>(0);
  // Periodic decay timer for the synthetic level bump (see
  // [_bumpSyntheticLevel] / [_onVoiceResult]). Once real amplitude
  // data starts arriving from the engine, the real callback resets
  // the timer and the synthetic path stops running.
  Timer? _voiceLevelDecayTimer;
  // Cached text of the previous partial transcript — used to detect
  // "the engine produced new content" so we can pulse the level
  // meter when no real amplitude data is available (e.g. on Windows,
  // where `speech_to_text`'s `onSoundLevelChange` is known to be
  // unreliable).
  String _lastRecognizedPartial = '';
  // True only once the engine confirms it is actually listening
  // (status == 'listening'). Used to distinguish a real recording
  // session from a long-press whose pointer was released because the
  // OS permission dialog appeared — in that case we must NOT stop the
  // session on release, or the user would never get to record.
  bool _voiceActuallyStarted = false;
  // Snapshot of the input box's text + cursor position taken when
  // the long-press begins. The live transcript is inserted at
  // [_voiceInsertOffset] of this snapshot so we don't trample the
  // text the user already had.
  String _voiceOriginalText = '';
  int _voiceInsertOffset = 0;
  // Drag-to-cancel state. If the user moves their finger > the
  // threshold from the long-press origin before releasing, the
  // recording is aborted and the original text is restored.
  Offset? _voiceLongPressOrigin;
  bool _voiceCancelledByDrag = false;
  // One-shot "abort the in-flight _startVoice pipeline" flag.
  // Set when the user drags to cancel mid-press; checked by
  // [_startVoice] after every await so a session that was
  // spinning up in parallel with the cancel never reaches
  // `setState` and flips `_voiceListening` back to true. Unlike
  // `_voiceCancelledByDrag`, this is *not* reset by
  // [_resetVoiceState] (which runs synchronously and would
  // otherwise clobber the flag before the still-pending
  // `_startVoice` microtask resumes).
  bool _voiceAbortInFlight = false;
  static const double _kDragCancelThreshold = 80; // logical px
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _hasText = _controller.text.trim().isNotEmpty;
  }

  void _onTextChanged() {
    final has = _controller.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    if (_voiceListening) {
      // Tear-down path: we must not call setState (the framework
      // asserts on this during dispose), so call the engine
      // directly and clear the bools in place. The input box
      // is about to be disposed anyway.
      widget.voiceService.cancelListening();
      _voiceListening = false;
      _voiceActuallyStarted = false;
    }
    _voiceLevelDecayTimer?.cancel();
    _voiceLevelDecayTimer = null;
    _voiceLevelNotifier.dispose();
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

  // ---- Voice input -------------------------------------------------------
  //
  // UX summary (long-press to talk, release to stop, **no auto-send**):
  //
  //   1. User long-presses the action button. The button works the
  //      same whether the input is empty (mic icon) or already has
  //      text (send icon) — both flavours of the action button
  //      accept long-press. This matches the requested behaviour
  //      where long-press voice input is always available.
  //   2. We *first* run the explicit `requestPermission()` flow
  //      (via `permission_handler`) so the OS shows a reliable
  //      microphone dialog on Android — `speech_to_text`'s
  //      built-in prompt is unreliable on MIUI / EMUI / ColorOS and
  //      can fail silently. A `denied` / `permanentlyDenied` result
  //      short-circuits with a precise snackbar.
  //   3. We snapshot the input box's current text + cursor offset
  //      so the live transcript can be inserted at the right
  //      place without destroying the user's existing draft.
  //   4. While the user holds the button, every partial transcript
  //      is mirrored live into the input box at the snapshotted
  //      offset. The voice bar above the input shows the same text
  //      + a level meter as a redundant, always-visible indicator.
  //   5. On release, we *stop* the engine and leave the text in
  //      the input box. **We do NOT send.** The user reviews /
  //      edits and taps the (now-returned) send button when ready.
  //   6. Drag-away-to-cancel: if the user moves their finger
  //      > [_kDragCancelThreshold] from the long-press origin
  //      before releasing, the partial text is discarded and the
  //      original draft is restored. Standard WeChat-style affordance.

  void _showVoiceSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// Common long-press *start* handler used by both the mic button
  /// (empty input) and the send button (non-empty input). The
  /// pointer position is captured so the drag-to-cancel check
  /// (in [Listener]-driven `_onRawPointerMove` / the release
  /// handler) can compute the delta.
  void _onLongPressStart(LongPressStartDetails details) {
    _voiceLongPressOrigin = details.localPosition;
    _voiceCancelledByDrag = false;
    _startVoice();
  }

  /// Raw pointer move handler. We can't rely on
  /// [LongPressGestureRecognizer.onLongPressMoveUpdate] for
  /// drag-to-cancel because the recognizer's
  /// `postPressSlopTolerance` (default ~100 logical px) silently
  /// **rejects** the gesture when the pointer drifts past it,
  /// which suppresses the [LongPressEndDetails] we need in
  /// order to compute the cancel. Using a raw [Listener] lets
  /// us observe the pointer even when the recognizer has
  /// cancelled, so the drag-cancel still works at the natural
  /// 80 px threshold.
  void _onRawPointerMove(PointerMoveEvent event) {
    if (_voiceLongPressOrigin == null) return;
    final delta = (event.localPosition - _voiceLongPressOrigin!).distance;
    final shouldCancel = delta > _kDragCancelThreshold;
    if (shouldCancel != _voiceCancelledByDrag) {
      setState(() => _voiceCancelledByDrag = shouldCancel);
    }
  }

  /// Raw pointer up handler. We also observe pointer-up through
  /// the [Listener] so the drag-cancel / commit decision doesn't
  /// depend on the recognizer still being in the accepted state.
  /// The actual stop / commit logic is in
  /// [_handleLongPressRelease] which is shared between the
  /// recognizer-driven end and the raw pointer-up.
  void _onRawPointerUp(PointerUpEvent event) {
    _handleLongPressRelease(event.localPosition);
  }

  /// Common long-press *end* handler. Called when the user lifts
  /// their finger, *or* when the OS hijacks the gesture (e.g. the
  /// permission dialog appeared mid-press). Distinguishes the two
  /// via [_voiceActuallyStarted].
  ///
  /// The drag-to-cancel check is done in [_handleLongPressRelease]
  /// using the final pointer position: if the release is more than
  /// [_kDragCancelThreshold] away from the origin, we treat the
  /// gesture as a cancel and restore the pre-recording text. The
  /// flag flips regardless of [_voiceActuallyStarted] — the user's
  /// intent is clear (they moved their finger away), and the only
  /// reason [actually started] might be false is the engine hasn't
  /// reported 'listening' yet. We always stop/cancel the
  /// underlying recognizer on a drag-cancel and flip
  /// [_voiceAbortInFlight] so the still-pending `_startVoice`
  /// microtask sees the abort and refuses to flip
  /// `_voiceListening` back to true.
  Future<void> _onLongPressEnd(LongPressEndDetails details) async {
    await _handleLongPressRelease(details.localPosition);
  }

  /// Shared release handler used by both the [LongPressEndDetails]
  /// path (when the recognizer survives) and the raw
  /// [PointerUpEvent] path (when the recognizer has rejected due
  /// to slop tolerance). Either way, the user's intent is what
  /// matters: dragged past the threshold → cancel; otherwise →
  /// commit (if the engine had time to actually start).
  Future<void> _handleLongPressRelease(Offset releasePos) async {
    final origin = _voiceLongPressOrigin;
    _voiceLongPressOrigin = null;
    final dragged =
        origin != null &&
        (releasePos - origin).distance > _kDragCancelThreshold;
    if (dragged) {
      _voiceAbortInFlight = true;
      if (_voiceListening) {
        await widget.voiceService.stopListening();
      } else {
        // Engine hasn't entered the listening state yet (e.g. the
        // user dragged while the permission dialog was up). Cancel
        // any in-flight initialization to be safe.
        await widget.voiceService.cancelListening();
      }
      _resetVoiceState(restoreOriginal: true);
      return;
    }
    // Normal path: if the engine actually started (past the
    // permission dialog), stop it and leave the text in the box.
    // If the gesture was hijacked by the OS dialog, the session is
    // still alive — keep it running so the user can record after
    // they grant.
    if (_voiceActuallyStarted) {
      await _stopVoice();
    } else if (_voiceListening) {
      // The user released before the engine entered 'listening'
      // and did not drag away. Most likely the permission dialog
      // stole the gesture — do nothing, let the session continue.
    }
  }

  /// Common long-press *end* handler. Called when the user lifts
  /// their finger, *or* when the OS hijacks the gesture (e.g. the
  /// permission dialog appeared mid-press). Distinguishes the two
  /// via [_voiceActuallyStarted].
  ///
  /// The drag-to-cancel check is done in [_handleLongPressRelease]
  /// using the final pointer position: if the release is more than
  /// [_kDragCancelThreshold] away from the origin, we treat the
  /// gesture as a cancel and restore the pre-recording text. The
  /// flag flips regardless of [_voiceActuallyStarted] — the user's
  /// intent is clear (they moved their finger away), and the only
  /// reason [actually started] might be false is the engine hasn't
  /// reported 'listening' yet. We always stop/cancel the
  /// underlying recognizer on a drag-cancel and flip
  /// We also process the release through a raw [Listener] (see
  /// [_onRawPointerUp]) because the recognizer's
  /// `postPressSlopTolerance` (~100 logical px) silently rejects
  /// the gesture when the pointer drifts past it, which would
  /// suppress this callback on a real drag-cancel.

  void _resetVoiceState({bool restoreOriginal = false}) {
    if (!mounted) return;
    if (restoreOriginal) {
      _controller.value = TextEditingValue(
        text: _voiceOriginalText,
        selection: TextSelection.collapsed(offset: _voiceInsertOffset),
      );
    }
    _voiceLevelDecayTimer?.cancel();
    _voiceLevelDecayTimer = null;
    _voiceLevelNotifier.value = 0.0;
    setState(() {
      _voiceListening = false;
      _voiceActuallyStarted = false;
      _voiceLevel = 0.0;
      _voicePartial = '';
      _lastRecognizedPartial = '';
      _voiceLongPressOrigin = null;
      _voiceCancelledByDrag = false;
    });
  }

  Future<void> _startVoice() async {
    if (_voiceListening || !widget.enabled || widget.sending) return;
    // Reset the abort flag at the *start* of each new long-press
    // pipeline so a previous drag-cancel doesn't poison a fresh
    // attempt. From here on, [_voiceAbortInFlight] is the only
    // thing that can stop this pipeline mid-flight.
    _voiceAbortInFlight = false;
    final l10n = AppLocalizations.of(context);

    // 1. Permission first. `requestPermission` is the explicit,
    // reliable path — it pops the OS dialog if the user hasn't
    // been asked yet, or returns the existing state on a re-try.
    // This is what was missing on Android: the `speech_to_text`
    // plugin's implicit prompt is unreliable, and users saw a
    // generic "couldn't start" hint instead of a real dialog.
    final perm = await widget.voiceService.requestPermission();
    if (_voiceAbortInFlight) return;
    switch (perm) {
      case PlatformPermissionStatus.denied:
        _showVoiceSnack(l10n.chatVoicePermissionDenied);
        return;
      case PlatformPermissionStatus.permanentlyDenied:
        _showVoiceSnack(l10n.chatVoicePermanentlyDenied);
        return;
      case PlatformPermissionStatus.notSupported:
        _showVoiceSnack(l10n.chatVoiceUnavailable);
        return;
      case PlatformPermissionStatus.granted:
        break;
    }

    // 2. Snapshot the input box so the live transcript can be
    // inserted at the right place without clobbering the user's
    // existing draft. The caret is clamped to a valid offset in
    // case the field was programmatically empty.
    _voiceOriginalText = _controller.text;
    final caret = _controller.selection.baseOffset;
    _voiceInsertOffset = (caret >= 0 && caret <= _voiceOriginalText.length)
        ? caret
        : _voiceOriginalText.length;

    // 3. Start the engine. Failure here means the recognizer
    // can't come up (e.g. no Google speech services on a Chinese
    // ROM); surface a precise error via [lastError].
    final started = await widget.voiceService.startListening(
      onResult: _onVoiceResult,
      onStatus: _onVoiceStatus,
      onLevel: _onVoiceLevel,
    );
    // Re-check after the second await — a drag-cancel that fired
    // while the recognizer was spinning up flips this flag and
    // tells us to abort cleanly without ever entering the
    // listening state.
    if (_voiceAbortInFlight) {
      if (started) await widget.voiceService.cancelListening();
      return;
    }
    if (!started) {
      final err = widget.voiceService.lastError;
      switch (err) {
        case VoiceError.permissionDenied:
          _showVoiceSnack(l10n.chatVoicePermissionDenied);
        case VoiceError.permanentlyDenied:
          _showVoiceSnack(l10n.chatVoicePermanentlyDenied);
        case VoiceError.unavailable:
          _showVoiceSnack(l10n.chatVoiceUnavailable);
        case VoiceError.unknown:
        case VoiceError.none:
          _showVoiceSnack(l10n.chatVoiceListenFailed);
      }
      return;
    }
    // Final abort check right before flipping _voiceListening. The
    // recognizer may have completed its async `listen()` faster
    // than the user-managed `onLongPressEnd` could set
    // _voiceAbortInFlight — in which case the microtask above
    // already returned `started = true` and we landed here. The
    // flag is the only race-safe signal we have for "drop the
    // session you were about to activate".
    if (_voiceAbortInFlight) {
      await widget.voiceService.cancelListening();
      return;
    }
    setState(() {
      _voiceListening = true;
      _voiceLevel = 0.0;
      _voicePartial = '';
      _voiceActuallyStarted = false;
      _lastRecognizedPartial = '';
    });
  }

  void _onVoiceResult(VoiceResult result) {
    if (!mounted) return;
    // The engine can fire a trailing partial *after* we've already
    // stopped the session (e.g. the user dragged to cancel and we
    // called `stopListening`, but the OS still had one more
    // chunk in the pipeline). Ignore anything that arrives while
    // we're not actively listening — otherwise a late result
    // would re-mirror text into the input box that the user just
    // had us clear.
    if (!_voiceListening) return;
    // Treat the first real, non-empty result as definitive proof
    // the session is alive. We no longer rely solely on
    // `onStatus('listening')` because on Windows the WinRT
    // speech engine sometimes never fires that string even while
    // delivering results — leaving the release-long-press path
    // stuck in the "engine never entered listening, do nothing"
    // branch and orphaning the session.
    final becameStarted = !_voiceActuallyStarted && result.text.isNotEmpty;
    if (becameStarted) _voiceActuallyStarted = true;
    final updated = result.text != _lastRecognizedPartial;
    setState(() => _voicePartial = result.text);
    if (updated) {
      _lastRecognizedPartial = result.text;
      // Pulse the volume meter on every genuinely new partial —
      // some platforms (notably Windows) never emit
      // `onSoundLevelChange`, so without this the user would see
      // a frozen meter while speaking.
      if (result.text.isNotEmpty) _bumpSyntheticLevel();
    }
    // Mirror the live transcript into the input box at the
    // snapshotted offset so the user sees their words being typed
    // in real time. The original prefix + suffix is preserved
    // untouched; only the "live" middle is rewritten on each
    // partial. The caret is moved to the end of the live text so
    // the user can keep typing after release if they want.
    final prefix = _voiceOriginalText.substring(0, _voiceInsertOffset);
    final suffix = _voiceOriginalText.substring(_voiceInsertOffset);
    _controller.value = TextEditingValue(
      text: '$prefix${result.text}$suffix',
      selection: TextSelection.collapsed(
        offset: prefix.length + result.text.length,
      ),
    );
  }

  void _onVoiceStatus(String status) {
    if (status == 'listening') {
      // Ignore late "listening" events that arrive after we have
      // already stopped the session (e.g. the user dragged to
      // cancel and we called `stopListening`, but the engine
      // had a delayed 'listening' still in flight).
      if (!_voiceListening) return;
      // The session is truly recording now (past any permission
      // prompt). From here on, releasing the long-press will stop
      // the session and leave the text in the box.
      if (mounted && !_voiceActuallyStarted) {
        setState(() => _voiceActuallyStarted = true);
      }
      return;
    }
    if (status == 'notListening' || status == 'done') {
      if (!_voiceListening) return;
      // The engine ended on its own (silence / max duration /
      // error-with-cancelOnError). The text up to this point is
      // already in the input box, so we just clean up the
      // listening flag — we do NOT send.
      if (mounted) {
        setState(() {
          _voiceListening = false;
          _voiceActuallyStarted = false;
        });
      }
    }
  }

  void _onVoiceLevel(double level) {
    if (!mounted) return;
    // The engine produced a real amplitude sample; trust it and
    // let the meter follow the actual waveform. Cancel the
    // synthetic decay so the bar doesn't drop when the engine
    // goes momentarily silent between samples.
    _voiceLevelDecayTimer?.cancel();
    _voiceLevelDecayTimer = null;
    final clamped = level.clamp(0.0, 1.0);
    _voiceLevelNotifier.value = clamped;
    setState(() => _voiceLevel = clamped);
  }

  /// Drive the volume meter from new partial transcripts when the
  /// underlying engine doesn't deliver `onSoundLevelChange` updates
  /// (the WinRT [speech_to_text] backend on Windows is one such
  /// case). Each new partial bumps the level to a randomised value
  /// in `0.55..0.95` and a decaying timer walks it back down so
  /// the visual feels organic even with no amplitude data.
  void _bumpSyntheticLevel() {
    final pulse = 0.55 + math.Random().nextDouble() * 0.40;
    final next = math.max(_voiceLevel, pulse);
    _voiceLevel = next;
    _voiceLevelNotifier.value = next;
    _scheduleSyntheticDecay();
  }

  void _scheduleSyntheticDecay() {
    _voiceLevelDecayTimer?.cancel();
    _voiceLevelDecayTimer = Timer.periodic(const Duration(milliseconds: 90), (
      t,
    ) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final next = math.max(0.0, _voiceLevel - 0.06);
      _voiceLevel = next;
      _voiceLevelNotifier.value = next;
      if (next <= 0.0001) {
        _voiceLevel = 0.0;
        _voiceLevelNotifier.value = 0.0;
        t.cancel();
        _voiceLevelDecayTimer = null;
      }
    });
  }

  Future<void> _stopVoice() async {
    if (!_voiceListening) return;
    await widget.voiceService.stopListening();
    if (mounted) {
      _voiceLevelDecayTimer?.cancel();
      _voiceLevelDecayTimer = null;
      _voiceLevelNotifier.value = 0.0;
      setState(() {
        _voiceListening = false;
        _voiceActuallyStarted = false;
        _voiceLevel = 0.0;
      });
    }
  }

  // `speech_to_text` owns its own listen timeout / pause timeout, so we
  // don't need a manual countdown here — the engine reports
  // `notListening`/`done` via [onStatus] when it ends on its own.

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
            if (_voiceListening) _buildVoiceBar(l10n),
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
                      voiceLevelNotifier: _voiceLevelNotifier,
                      voiceActive: _voiceListening,
                      voiceDragCancelled: _voiceCancelledByDrag,
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
                      : _buildActionButton(context),
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

  /// The right-hand action button.
  ///
  ///   * **Listening** → pulsing mic, tap to stop. The text already
  ///     lives in the input box from the live-transcript updates.
  ///   * **Has text (idle)** → send button. *Tap* sends the message;
  ///     *long-press* starts voice input. Both gestures are bound on
  ///     the same button so the user can always long-press the send
  ///     key to start a voice session, regardless of whether the
  ///     input is empty.
  ///   * **Empty (idle)** → mic button. *Tap* focuses typing;
  ///     *long-press* starts voice input. Same long-press path as
  ///     the send-button branch — it goes through the same
  ///     permission check + live-transcript pipeline.
  ///
  /// Long-press is delivered through `GestureDetector` rather than
  /// the `ElevatedButton`'s own long-press handler (which doesn't
  /// exist), and supports drag-to-cancel via
  /// [_onLongPressMoveUpdate].
  Widget _buildActionButton(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasText = _hasText;

    if (_voiceListening) {
      // While recording, a tap stops. The text is already in the
      // input box via the live-transcript updates; we do NOT send.
      return GestureDetector(
        onTap: _stopVoice,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppTheme.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.4),
                blurRadius: 8 + _voiceLevel * 16,
                spreadRadius: _voiceLevel * 4,
              ),
            ],
          ),
          child: const Icon(Icons.mic, color: Colors.white, size: 18),
        ),
      );
    }

    // Long-press gesture shared by both the send button (when
    // there's text) and the mic button (when the input is empty).
    // On Android / iOS the long-press starts voice input; on
    // desktop / web, where the mic path is rarely useful, the
    // empty-input branch still wires long-press for parity, but
    // [_startVoice] shows the "unavailable" snackbar if the
    // platform can't actually capture audio.
    //
    // Drag-to-cancel is resolved inside [_onLongPressEnd] (not
    // via `onLongPressMoveUpdate`) for reliability — see the
    // comment on [_onLongPressStart].
    final longPressHandlers = <String, dynamic>{
      'onLongPressStart': _onLongPressStart,
      'onLongPressEnd': _onLongPressEnd,
    };

    // Both buttons share a raw [Listener] wrap so the drag-to-cancel
    // detection in [_onRawPointerMove] / [_onRawPointerUp] survives
    // even when the LongPressGestureRecognizer has been rejected
    // by the post-press slop tolerance. The Listener is set to
    // [HitTestBehavior.translucent] so it doesn't eat the gestures
    // that the inner GestureDetector / ElevatedButton rely on.
    if (hasText) {
      // Send button. Tap sends; long-press starts voice input. We
      // use a GestureDetector over the visual button so we can
      // own the long-press gesture without fighting the
      // ElevatedButton's tap handler. The ElevatedButton's
      // onPressed is wired to the same tap callback so the
      // visual feedback (ripple) is consistent.
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: _onRawPointerMove,
        onPointerUp: _onRawPointerUp,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart:
              longPressHandlers['onLongPressStart']
                  as void Function(LongPressStartDetails)?,
          onLongPressEnd:
              longPressHandlers['onLongPressEnd']
                  as void Function(LongPressEndDetails)?,
          child: ElevatedButton(
            onPressed: widget.enabled ? _send : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.4),
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
      );
    }

    // Empty input: mic button. Tap focuses typing; long-press
    // starts voice input. Same long-press pipeline as the
    // send-button branch above. We deliberately do *not* wrap the
    // icon in a [Tooltip] here — the `Tooltip` widget installs its
    // own internal `LongPressGestureRecognizer` that wins the
    // gesture arena and would eat the outer GestureDetector's
    // long-press before our handler runs. The discoverability hint
    // is provided by the [Semantics] label below, which screen
    // readers + the chat toolbar's long-press hint cover.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: _onRawPointerMove,
      onPointerUp: _onRawPointerUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _focusNode.requestFocus(),
        onLongPressStart:
            longPressHandlers['onLongPressStart']
                as void Function(LongPressStartDetails)?,
        onLongPressEnd:
            longPressHandlers['onLongPressEnd']
                as void Function(LongPressEndDetails)?,
        child: Semantics(
          button: true,
          label: l10n.chatMicTooltip,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.primary,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.mic_none_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  /// Live transcript + level meter shown while voice capture is active.
  Widget _buildVoiceBar(AppLocalizations l10n) {
    // Three states: pre-listening hint, mid-recording partial,
    // drag-cancelled warning. The transcript itself is also being
    // mirrored into the input box in real time — this bar is the
    // always-visible redundant indicator (in case the input box
    // is occluded by the keyboard).
    final String text;
    final Color color;
    final IconData icon;
    if (_voiceCancelledByDrag) {
      text = l10n.chatVoiceDragToCancel;
      color = Colors.redAccent;
      icon = Icons.close_rounded;
    } else if (_voicePartial.isNotEmpty) {
      text = _voicePartial;
      color = context.textPrimary;
      icon = Icons.mic;
    } else {
      text = l10n.chatMicListeningHint;
      color = context.textSecondary;
      icon = Icons.mic_none_rounded;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: _voiceCancelledByDrag ? color : AppTheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 48,
            height: 18,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(5, (i) {
                // Cheap pseudo-bars driven by the mic level so the UI
                // feels alive without a real frequency analyser.
                final threshold = i / 5.0;
                final active = _voiceLevel >= threshold;
                return Container(
                  width: 4,
                  height: 6 + (active ? _voiceLevel * 10 : 0),
                  decoration: BoxDecoration(
                    color: _voiceCancelledByDrag
                        ? (active ? color : context.appBorder)
                        : (active ? AppTheme.primary : context.appBorder),
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              }),
            ),
          ),
        ],
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
///
/// When [voiceActive] is `true` the field shows a left-anchored
/// gradient bar (green → yellow → red, width proportional to
/// [voiceLevelNotifier].value) as the live volume meter. This is
/// the user-visible feedback for voice input: louder sound =
/// wider bar; no sound = bar collapses to zero. The bar lives
/// *behind* the [TextField] (in a [Stack]) so the text stays
/// fully readable; on a drag-to-cancel the gradient flips to a
/// red/orange tint via [voiceDragCancelled].
class _InputField extends StatefulWidget {
  const _InputField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.sending,
    required this.onSubmit,
    this.onPaste,
    this.voiceLevelNotifier,
    this.voiceActive = false,
    this.voiceDragCancelled = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool sending;
  final VoidCallback onSubmit;
  final VoidCallback? onPaste;

  /// Live 0..1 amplitude sample (or a synthetic pulse) emitted by
  /// the parent while a voice session is active. The input listens
  /// to this notifier so the background gradient repaints without
  /// rebuilding the whole chat input column on every sample.
  final ValueListenable<double>? voiceLevelNotifier;

  /// Whether a voice session is currently active. While `false`
  /// the gradient collapses to zero width and stays invisible
  /// regardless of the level notifier's value.
  final bool voiceActive;

  /// `true` while the user is dragging-to-cancel. Switches the
  /// gradient to a red/orange palette so the input itself doubles
  /// as a cancel affordance, matching the red text + icon in the
  /// voice bar above it.
  final bool voiceDragCancelled;

  @override
  State<_InputField> createState() => _InputFieldState();
}

class _InputFieldState extends State<_InputField> {
  @override
  void initState() {
    super.initState();
    widget.voiceLevelNotifier?.addListener(_onLevelChanged);
  }

  @override
  void didUpdateWidget(covariant _InputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.voiceLevelNotifier != widget.voiceLevelNotifier) {
      oldWidget.voiceLevelNotifier?.removeListener(_onLevelChanged);
      widget.voiceLevelNotifier?.addListener(_onLevelChanged);
    }
  }

  @override
  void dispose() {
    widget.voiceLevelNotifier?.removeListener(_onLevelChanged);
    super.dispose();
  }

  void _onLevelChanged() {
    if (mounted) setState(() {});
  }

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
      if (isPasteModifier && widget.onPaste != null) {
        widget.onPaste!();
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
    if (!widget.enabled) return KeyEventResult.ignored;
    widget.onSubmit();
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
    if (!widget.enabled && widget.sending) return l10n.chatInputHintReplying;
    if (!widget.enabled) return l10n.chatInputHintNoModel;
    return l10n.chatInputHint;
  }

  @override
  Widget build(BuildContext context) {
    // Read the level locally so the bar repaints whenever the
    // notifier fires, even when the parent ChatInput didn't
    // rebuild. Clamp to [0, 1] to keep fractional-noise from
    // plugins (some report >1 dB) from over-filling the bar.
    final rawLevel = widget.voiceActive
        ? (widget.voiceLevelNotifier?.value ?? 0.0)
        : 0.0;
    final factor = (0.02 + rawLevel.clamp(0.0, 1.0) * 0.98).clamp(0.02, 1.0);
    return Focus(
      onKeyEvent: _onKey,
      child: Stack(
        children: [
          // Volume-monitor background. Sits behind the [TextField]
          // (Stack children paint in order). `fillColor: transparent`
          // lets the gradient show through the field's fill area; the
          // rounded `ClipRRect` matches the field's `borderRadius`
          // so the bar never bleeds past the rounded corners.
          if (widget.voiceActive)
            Positioned.fill(
              // Volume-monitor background. The bar's width is the
              // raw `level` (left-anchored via `FractionallySizedBox`
              // + `Align`). We deliberately do *not* tween between
              // samples here — the synthetic-decay timer already
              // walks the level down in 60 ms ticks, which gives a
              // smoother-looking animation than any tween between
              // discrete samples would, and avoids the
              // TweenAnimationBuilder-restart race that periodic
              // updates can trigger. The 2% baseline keeps a thin
              // sliver visible at zero amplitude so the field
              // still reads as "live" between phrases.
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: factor,
                    heightFactor: 1,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: widget.voiceDragCancelled
                              ? const [
                                  Color(0xFFFFCDD2), // red 100
                                  Color(0xFFE57373), // red 300
                                  Color(0xFFEF5350), // red 400
                                ]
                              : const [
                                  Color(0xFF81C784), // green 300
                                  Color(0xFFFFF176), // yellow 300
                                  Color(0xFFE57373), // red 300
                                ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            enabled: widget.enabled,
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
              filled: true,
              // Transparent fill so the gradient volume bar painted
              // behind this TextField (via the Stack above) shows
              // through. The OutlineInputBorder still draws the
              // rounded outline on top.
              fillColor: Colors.transparent,
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
                borderSide: const BorderSide(
                  color: AppTheme.primary,
                  width: 1.2,
                ),
              ),
              isDense: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Left-anchored colored bar that fills `level`-fraction of its
/// container. Width is proportional to the live microphone
/// amplitude; the palette is a horizontal gradient that flows
/// green → yellow → red by default and switches to a
/// red-only "cancel warning" palette while [dragCancelled] is
/// `true`. The full gradient spans the bar's actual width, so at
/// low volumes only the leftmost (green) part of the palette is
/// visible; at high volumes the yellow / red end of the rainbow
/// slides into view. A 2% baseline strip keeps the bar visible
/// even at zero amplitude so the user knows the field is in
/// "live" mode between phrases.

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
