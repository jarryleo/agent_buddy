import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/edited_image.dart';
import '../models/file_attachment.dart';
import '../models/message.dart';
import '../providers/chat_provider.dart';
import '../services/tts_service.dart';
import '../theme/app_theme.dart';
import 'image_preview.dart';
import 'download_card.dart';
import 'edit_image_card.dart';
import 'markdown_content.dart';

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onCopy,
    this.groupedToolMessages,
  });

  final ChatMessage message;
  final ValueChanged<String> onCopy;

  /// When non-null, this bubble renders a collapsed group of
  /// consecutive tool-role messages instead of the normal message
  /// layout. The [message] field is used for the copy callback.
  final List<ChatMessage>? groupedToolMessages;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();

  /// Produces one `ValueKey`-friendly string per `ToolCall` in
  /// [calls], disambiguating duplicates by appending `#<n>` to
  /// the 2nd, 3rd, �?occurrence of the same id. The first
  /// occurrence keeps the bare `tool_<id>` form so a single
  /// non-colliding call still matches the key the rest of the
  /// codebase (retry / `resolveAskUser`) looks up by.
  ///
  /// This is the last line of defense against the
  /// "Duplicate keys found" crash: the chat provider already
  /// mints unique ids upstream, and `LocalLlmService` always
  /// synthesizes a fresh one, but a stale / replayed message,
  /// or any future code path that forgets the rule, would
  /// still crash the Column without this pass.
  @visibleForTesting
  static List<String> disambiguateToolCallKeys(List<ToolCall> calls) {
    final seenIds = <String, int>{};
    return [
      for (final tc in calls) ...[
        () {
          final occurrence = seenIds[tc.id] ?? 0;
          seenIds[tc.id] = occurrence + 1;
          return occurrence == 0
              ? 'tool_${tc.id}'
              : 'tool_${tc.id}#$occurrence';
        }(),
      ],
    ];
  }
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _thinkingExpanded = false;
  bool _toolCallsExpanded = false;
  static const int _thinkingCollapsedLines = 3;
  static const int _thinkingExpandedLines = 10;
  static const double _autoScrollBottomTolerance = 24;

  final ScrollController _thinkingScroll = ScrollController();
  bool _thinkingAtBottom = true;
  String _lastThinking = '';
  int _lastExpandedLines = _thinkingCollapsedLines;

  /// Cached snapshot of [TtsService.speakingMessageId] for this
  /// bubble's id. Updated by [_onTtsSpeakingChanged]. Compared
  /// during [build] to decide whether to render the speaker
  /// button in its `volume_up` (other message is speaking),
  /// `stop` (this message is speaking), or `play_arrow`
  /// (paused) state.
  bool _ttsIsThisMessage = false;
  bool _ttsIsPaused = false;

  /// Cached snapshot of [TtsService.isSupportedNotifier.value].
  /// Drives the speak button's visibility (see [_buildTtsSpeaker]).
  /// Starts `false`; flips to the engine's answer once the
  /// post-frame callback in [initState] reads the service, *and*
  /// whenever the service's notifier fires (probe lands, hot-
  /// reload, etc.). The cache exists so [build] can read a sync
  /// bool instead of doing a Provider lookup on every paint.
  bool _ttsIsSupported = false;

  @override
  void initState() {
    super.initState();
    _thinkingScroll.addListener(_onThinkingScroll);
    // We can't `context.read<TtsService>()` in initState (the
    // BuildContext isn't ready for inherited-widget lookups yet),
    // so we defer the first read + listener attach to a
    // post-frame callback. By that point the build is done and
    // context is valid. The subscription is one-way: the service
    // owns the truth, we only listen.
    //
    // `_lookupTts` returns `null` if no `Provider<TtsService>` is
    // in the tree — that happens only in unit tests that pre-date
    // the TTS feature. Production always supplies the Provider
    // via `main.dart`, so this branch is purely a safety net.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tts = _lookupTts(context);
      if (tts == null) return;
      _syncTtsState(tts);
      // Seed the supported snapshot from the live notifier
      // value, then trigger a rebuild if it differs from the
      // initial `false`. This is what makes the speaker button
      // pop into view the moment the post-frame callback runs
      // (instead of staying hidden until the user triggers
      // a state change later).
      final supported = tts.isSupported;
      if (supported != _ttsIsSupported) {
        setState(() {
          _ttsIsSupported = supported;
        });
      }
      tts.speakingMessageId.addListener(_onTtsSpeakingChanged);
      tts.isPausedNotifier.addListener(_onTtsPausedChanged);
      tts.isSupportedNotifier.addListener(_onTtsSupportedChanged);
    });
  }

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The service is shared across bubbles (singleton via
    // Provider). Our snapshot already reflects the current state,
    // but if the message identity changed (e.g. via hot-reload)
    // we want to re-evaluate against the new id before the next
    // build.
    if (oldWidget.message.id != widget.message.id && mounted) {
      final tts = _lookupTts(context);
      if (tts != null) _syncTtsState(tts);
    }
  }

  @override
  void dispose() {
    _thinkingScroll.removeListener(_onThinkingScroll);
    _thinkingScroll.dispose();
    // Detach the listeners we registered in initState's
    // post-frame callback. The listener removal only needs the
    // *service* — read it once defensively. `_lookupTts` returns
    // `null` when the provider tree is already gone (test
    // teardown, app shutdown), in which case there's nothing to
    // detach.
    final tts = _lookupTts(context);
    if (tts != null) {
      tts.speakingMessageId.removeListener(_onTtsSpeakingChanged);
      tts.isPausedNotifier.removeListener(_onTtsPausedChanged);
      tts.isSupportedNotifier.removeListener(_onTtsSupportedChanged);
    }
    super.dispose();
  }

  /// Optional lookup of the [TtsService] �?returns `null` when no
  /// `Provider<TtsService>` is in scope. The production app always
  /// supplies the Provider via `main.dart`, but pre-existing
  /// bubble unit tests pre-date the feature, and we'd rather they
  /// keep rendering than crash on `context.read`. Returning `null`
  /// means the bubble's TTS affordance stays hidden.
  static TtsService? _lookupTts(BuildContext context) {
    try {
      return Provider.of<TtsService>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  /// Pull the current speaking-id + paused flag from the service
  /// and refresh our cached snapshot. Called on first attach and
  /// after `didUpdateWidget`.
  void _syncTtsState(TtsService tts) {
    _ttsIsThisMessage = tts.speakingMessageId.value == widget.message.id;
    _ttsIsPaused = _ttsIsThisMessage && tts.isPausedNotifier.value;
  }

  void _onTtsSpeakingChanged() {
    if (!mounted) return;
    final tts = _lookupTts(context);
    if (tts == null) return;
    final newValue = tts.speakingMessageId.value == widget.message.id;
    if (newValue != _ttsIsThisMessage) {
      setState(() {
        _ttsIsThisMessage = newValue;
      });
    }
  }

  void _onTtsPausedChanged() {
    if (!mounted) return;
    // Pausing only matters to the bubble that's currently
    // speaking. Other bubbles (idle or waiting their turn) ignore
    // the pause flag — it has no visual effect on them.
    if (!_ttsIsThisMessage) return;
    final tts = _lookupTts(context);
    if (tts == null) return;
    final newValue = tts.isPausedNotifier.value;
    if (newValue != _ttsIsPaused) {
      setState(() {
        _ttsIsPaused = newValue;
      });
    }
  }

  /// Fired when the engine probe lands and the `isSupported`
  /// flag flips. Triggers a rebuild so the speaker button can
  /// pop into view (or hide itself on a platform without TTS).
  /// Without this listener the bubble would stay in its
  /// pre-probe state forever and the user would never see the
  /// speaker icon.
  void _onTtsSupportedChanged() {
    if (!mounted) return;
    final tts = _lookupTts(context);
    if (tts == null) return;
    final newValue = tts.isSupported;
    if (newValue != _ttsIsSupported) {
      setState(() {
        _ttsIsSupported = newValue;
      });
    }
  }

  void _onThinkingScroll() {
    if (!_thinkingScroll.hasClients) return;
    final pos = _thinkingScroll.position;
    final atBottom =
        pos.pixels >= pos.maxScrollExtent - _autoScrollBottomTolerance;
    if (atBottom != _thinkingAtBottom) {
      _thinkingAtBottom = atBottom;
    }
  }

  void _scheduleAutoScrollThinking(bool wasAtBottom) {
    // We only schedule if the user was at the bottom BEFORE the new
    // content was laid out. After layout, `pixels` still points at the
    // old maxScrollExtent while `maxScrollExtent` has grown, so a
    // re-check in the post-frame callback would incorrectly think the
    // user is no longer at the bottom and skip the jump. Snapshot the
    // intent here, and just `jumpTo(newMaxExtent)` in the callback.
    if (!wasAtBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_thinkingScroll.hasClients) return;
      final pos = _thinkingScroll.position;
      _thinkingScroll.jumpTo(pos.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    // Hidden messages are still part of the conversation (the model
    // sees them in the request list) but the user should never see
    // them as a bubble. This is used by the timer-driven flow: the
    // chat provider appends a synthetic "[系统计时触发] <label>" user
    // message so the model can react, but the UI skips it so the
    // user just sees the AI's reminder response.
    if (m.hidden) return const SizedBox.shrink();
    if (widget.groupedToolMessages != null) {
      return _buildGroupedToolCalls(context, widget.groupedToolMessages!);
    }
    final body = m.role == MessageRole.user
        ? _buildUser(context, m)
        : _buildAssistant(context, m);
    if (m.role == MessageRole.assistant) {
      final maxLines = _thinkingExpanded
          ? _thinkingExpandedLines
          : _thinkingCollapsedLines;
      final thinkingChanged = m.thinking != _lastThinking;
      final expandedChanged = maxLines != _lastExpandedLines;
      if (thinkingChanged || expandedChanged) {
        // Snapshot the bottom state BEFORE updating _lastThinking,
        // so a listener that fires during layout (and may flip
        // _thinkingAtBottom to false because the old position is no
        // longer at the new bottom) cannot retroactively cancel the
        // auto-scroll we want to do for the next frame's worth of
        // thinking tokens.
        final wasAtBottom = _thinkingAtBottom;
        _lastThinking = m.thinking;
        _lastExpandedLines = maxLines;
        _scheduleAutoScrollThinking(wasAtBottom);
      }
    }
    // RepaintBoundary isolates each message's layer so a streaming
    // re-render of the latest assistant message doesn't trigger a
    // repaint of the entire chat list (which is exactly what
    // ListView.builder already does for free �?but the explicit
    // RepaintBoundary also stops a Paint pass from re-rasterizing
    // sibling messages when the streaming layer grows).
    return RepaintBoundary(child: body);
  }

  Widget _buildUser(BuildContext context, ChatMessage m) {
    final hasImages = m.imagePaths.isNotEmpty;
    final hasFiles = m.fileAttachments.isNotEmpty;
    final hasAttachments = hasImages || hasFiles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 4, 12, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (hasImages) _buildUserImages(context, m.imagePaths),
                if (hasImages && hasFiles) const SizedBox(height: 6),
                if (hasFiles) _buildUserFiles(context, m.fileAttachments),
                if (hasAttachments && m.content.isNotEmpty)
                  const SizedBox(height: 6),
                if (m.content.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: context.bubbleUser,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(4),
                      ),
                    ),
                    child: Text(
                      m.content,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                  ),
                if (m.content.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat('HH:mm').format(m.createdAt.toLocal()),
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => widget.onCopy(m.content),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 12,
                            color: context.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserImages(BuildContext context, List<String> paths) {
    final maxWidth = MediaQuery.of(context).size.width * 0.65;
    final isMulti = paths.length > 1;
    // Larger thumbnails than the legacy 160 / 88dp default �?uploaded photos
    // are usually the user's main subject and benefit from being readable at
    // a glance.
    final thumbSize = isMulti ? 300.0 : 600.0;
    final crossAxisCount = isMulti ? (paths.length >= 3 ? 2 : paths.length) : 1;
    // Actual on-screen cell side after the grid's crossAxisSpacing. The
    // Image widget's `width` / `height` is only a hint here �?the grid
    // derives the cell from `childAspectRatio: 1`, so on single-image rows
    // the rendered thumbnail is the full bubble width, not thumbSize.
    final cellSide = (maxWidth - 4 * (crossAxisCount - 1)) / crossAxisCount;
    // Decode the cached bitmap at the displayed cell × dpr, not thumbSize
    // × dpr. The previous cacheSize = thumbSize * dpr was *smaller* than
    // the actual display footprint on single-image rows
    // (cell ~260dp > thumbSize 160dp), so Flutter had to up-sample the
    // cache to the screen �?that's the source of the visibly pixelated
    // cover-cropped thumbnail. ResizeImage caps at the source file's
    // native dimensions, so requesting more pixels than the file holds
    // is a harmless no-op (no up-sampling at decode time).
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (cellSide * dpr)
        .clamp((thumbSize * dpr).roundToDouble(), 4096.0)
        .round();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: paths.length,
        itemBuilder: (context, index) {
          final path = paths[index];
          return GestureDetector(
            onTap: () => ImagePreviewPage.showLocal(context, path),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: RepaintBoundary(
                // Each thumbnail is its own repaint layer so the
                // rest of the chat list doesn't repaint when one
                // image finishes decoding.
                child: Image(
                  image: ResizeImage(
                    FileImage(File(path)),
                    width: cacheSize,
                    height: cacheSize,
                    policy: ResizeImagePolicy.fit,
                  ),
                  width: thumbSize,
                  height: thumbSize,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
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
            ),
          );
        },
      ),
    );
  }

  Widget _buildUserFiles(BuildContext context, List<ChatFileAttachment> files) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final file in files)
          Container(
            constraints: const BoxConstraints(maxWidth: 230),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: context.bubbleAssistant,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.appBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 20,
                  color: AppTheme.primary,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _formatFileSize(file.size),
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Widget _buildGroupedToolCalls(
    BuildContext context,
    List<ChatMessage> messages,
  ) {
    final allCalls = <ToolCall>[];
    for (final m in messages) {
      allCalls.addAll(m.toolCalls);
    }
    return _GroupedToolCalls(
      messages: messages,
      allCalls: allCalls,
      onCopy: widget.onCopy,
    );
  }

  Widget _buildAssistant(BuildContext context, ChatMessage m) {
    final hasThinking = m.thinking.isNotEmpty;
    final hasTools = m.toolCalls.isNotEmpty;
    final hasEditedImages = m.toolCalls.any((tc) => tc.editedImages.isNotEmpty);
    final isRetrying = m.isRetrying;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isRetrying) _buildRetryBanner(context, m),
          if (hasThinking) _buildThinking(context, m),
          if (hasTools) _buildToolCallsSection(context, m),
          // Edited-image gallery: rendered as a sibling of the
          // tool-calls section, NOT inside the collapsed tool
          // card. The user picked "directly visible in the
          // bubble content area" over "collapsed with the rest
          // of the tool call" — a 4-step chain of compress /
          // resize / rotate / crop is most useful when the
          // previews are all on screen at once, and the
          // metadata captions (action · WxH · bytes) make the
          // sequence self-explanatory even without the
          // collapsed card's args panel.
          if (hasEditedImages) _buildEditedImagesGallery(context, m),
          // Bubble + footer are sized together so the footer
          // [Spacer] can push chips flush against the bubble's
          // right edge. The [IntrinsicWidth] is scoped to JUST
          // this pair (not the whole column) so the thinking
          // and tool-call blocks above don't stretch the bubble
          // to their width �?during streaming that's the
          // difference between a tightly-wrapped bubble and a
          // hollow-looking one with the answer hugging the
          // left edge.
          //
          // [IntrinsicWidth] costs an extra layout pass per
          // message; the chat list is paginated enough that
          // the hit isn't visible.
          IntrinsicWidth(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (m.content.isNotEmpty || m.streaming)
                  // The bubble + the TTS button share a Stack so the
                  // button can sit at the bubble's bottom-right
                  // without affecting the content's layout �?the
                  // markdown gets the full bubble width, and the
                  // button overlays the bottom-right ~6px without
                  // pushing the text up.
                  //
                  // [Stack.clipBehavior.none] is the default but we
                  // spell it out so the button can render slightly
                  // outside the bubble's rounded corners (its
                  // [Positioned] rect is fine but a soft drop-shadow
                  // shouldn't be clipped to the bubble).
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        margin: EdgeInsets.only(
                          top: (hasThinking || hasTools) ? 6 : 0,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: context.bubbleAssistant,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(4),
                            topRight: Radius.circular(16),
                            bottomLeft: Radius.circular(16),
                            bottomRight: Radius.circular(16),
                          ),
                          border: Border.all(color: context.appBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _StreamingMarkdown(
                              data: m.content,
                              streaming: m.streaming,
                            ),
                            if (m.streaming) const _TypingIndicator(),
                          ],
                        ),
                      ),
                      // Speaker button �?only when there's
                      // something to speak. Positioned at the
                      // bubble's bottom-right corner with 2px of
                      // breathing room. The button paints OVER the
                      // markdown; on long messages it overlaps the
                      // last line slightly. That overlap is the
                      // intended affordance �?the button visually
                      // "owns" that corner of the bubble, and the
                      // markdown's last line rarely matters in
                      // practice (the tail of an assistant reply
                      // is typically whitespace or a list bullet).
                      if (m.content.isNotEmpty)
                        Positioned(
                          right: 2,
                          bottom: 2,
                          child: _buildTtsSpeaker(context),
                        ),
                    ],
                  ),
                // Footer: rendered BELOW the bubble, on the page
                // background (not inside the bubble's background).
                // Stretched to bubble width by the surrounding
                // Column's [crossAxisAlignment.stretch], so the
                // [Spacer] pushes the metric chips flush to the
                // bubble's right edge.
                //
                // Always rendered (even when content is empty)
                // so a turn that produced only reasoning tokens
                // still surfaces its timestamp + chips to the
                // user.
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Row(
                    children: [
                      Text(
                        DateFormat('HH:mm').format(m.createdAt.toLocal()),
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      if (m.content.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () => widget.onCopy(m.content),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.copy_rounded,
                              size: 12,
                              color: context.textSecondary,
                            ),
                          ),
                        ),
                      ],
                      if (m.metrics != null) ...[
                        const Spacer(),
                        ..._buildMetricChips(context, m.metrics!),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          // ask_user chips live at the very bottom of the bubble
          // (below the content + footer) so the model’s question
          // can’t be hidden inside a collapsed tool-call section.
          _buildAskUserQuestions(context, m),
        ],
      ),
    );
  }

  Widget _buildToolCallsSection(BuildContext context, ChatMessage m) {
    final l10n = AppLocalizations.of(context);
    final count = m.toolCalls.length;
    final successCount = m.toolCalls
        .where((c) => c.status == ToolCallStatus.success)
        .length;
    final failedCount = m.toolCalls
        .where((c) => c.status == ToolCallStatus.failed)
        .length;
    final runningCount = m.toolCalls
        .where((c) => c.status == ToolCallStatus.running)
        .length;
    return Container(
      decoration: BoxDecoration(
        color: context.toolCallBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.toolCallBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () =>
                setState(() => _toolCallsExpanded = !_toolCallsExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.build_outlined,
                    size: 14,
                    color: context.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.toolGroupSummary(count),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (runningCount > 0)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                      ),
                    )
                  else ...[
                    if (failedCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          '$failedCount/$count',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.errorText,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    if (successCount == count)
                      Icon(
                        Icons.check_circle_outline_rounded,
                        size: 14,
                        color: const Color(0xFF1F883D),
                      ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    _toolCallsExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: context.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_toolCallsExpanded) ...[
            const SizedBox(height: 6),
            _buildToolCalls(context, m.toolCalls),
          ],
        ],
      ),
    );
  }

  /// Gallery of `edit_image` results for this assistant
  /// message. Iterates over every tool call and concatenates
  /// their `editedImages` lists, then renders them in a
  /// `Wrap` so multiple cards (a 4-step chain) flow
  /// naturally without forcing a 2-column grid on a 1-card
  /// case.
  ///
  /// Each card is its own `EditImageCard` widget — they own
  /// the download affordance + the "expired" hint when the
  /// temp file is gone after an app restart.
  Widget _buildEditedImagesGallery(BuildContext context, ChatMessage m) {
    final entries = <_EditedImageEntry>[];
    for (final tc in m.toolCalls) {
      for (final img in tc.editedImages) {
        entries.add(_EditedImageEntry(toolId: tc.id, image: img));
      }
    }
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final e in entries)
            ConstrainedBox(
              // Cap each card to a sensible phone-bubble width
              // so a chain of N edits doesn't push the bubble
              // to full-screen on the wide side of the
              // phone-frame layout. The card's content is
              // AspectRatio-driven, so this constraint controls
              // the preview size rather than the caption.
              constraints: const BoxConstraints(maxWidth: 260),
              child: EditImageCard(
                image: e.image,
                assistantId: m.id,
                toolId: e.toolId,
              ),
            ),
        ],
      ),
    );
  }

  /// while the cloud provider path is waiting on the next
  /// attempt of the exponential-backoff schedule. Reads the live
  /// `m.nextRetryAt` on every rebuild so the countdown label
  /// updates second-by-second �?driven by the 1-second ticker
  /// inside [ChatProvider] (which calls `notifyListeners` while
  /// any message has a pending retry).
  ///
  /// Visually: a thin warning-tinted row with a refresh icon
  /// and the localized "网络抖动,�?N 次重�?X 秒后重连" label
  /// (or the English equivalent). Sits OUTSIDE the streaming
  /// bubble so the spinner / typewriter that lives inside the
  /// bubble never has to compete with the countdown label.
  Widget _buildRetryBanner(BuildContext context, ChatMessage m) {
    final l10n = AppLocalizations.of(context);
    final nextAt = m.nextRetryAt;
    final seconds = nextAt == null
        ? 0
        : nextAt.difference(DateTime.now()).inSeconds.clamp(0, 1 << 30);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        // A muted warning tone �?distinct from both the
        // bubble's assistant bg and the tool-call bg so the
        // user can read it at a glance but it doesn't look
        // like a hard error.
        color: const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6A23C)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.6,
              valueColor: AlwaysStoppedAnimation(Color(0xFFE6A23C)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.chatRetryStatus(
                m.retryAttempt.toString(),
                seconds.toString(),
              ),
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF8A5C00),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThinking(BuildContext context, ChatMessage m) {
    final l10n = AppLocalizations.of(context);
    final lineCount = '\n'.allMatches(m.thinking).length + 1;
    final maxLines = _thinkingExpanded
        ? _thinkingExpandedLines
        : _thinkingCollapsedLines;
    final overflow = lineCount > maxLines;
    final canToggle = _thinkingExpanded || overflow;
    return Container(
      decoration: BoxDecoration(
        color: context.thinkingBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.thinkingBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: canToggle
                ? () => setState(() => _thinkingExpanded = !_thinkingExpanded)
                : null,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 14,
                    color: Color(0xFFA37300),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l10n.messageThinking,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF8A5C00),
                    ),
                  ),
                  const Spacer(),
                  if (canToggle)
                    Icon(
                      _thinkingExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: const Color(0xFF8A5C00),
                    ),
                ],
              ),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: 24.0 * maxLines + 8),
            child: SingleChildScrollView(
              controller: _thinkingScroll,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                m.thinking,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: Color(0xFF6B4A00),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Renders the three "performance" chips that sit at the
  /// right edge of the assistant-bubble footer (after the
  /// [Spacer]):
  ///   * time-to-first-token (clock icon + "0.50s"),
  ///   * decode speed ("50t/s"),
  ///   * total token count for this turn (Σ icon + "1312token",
  /// The "read aloud" speaker button overlaid at the bottom-right
  /// of the assistant bubble. Three visual states, all driven by
  /// the cached [TtsService] notifiers:
  ///
  ///   * **Idle** (no message is being spoken): a muted
  ///     `volume_up` icon �?clicking it starts speaking this
  ///     bubble's content.
  ///   * **This bubble is speaking** (`_ttsIsThisMessage && !_ttsIsPaused`):
  ///     a filled `stop` icon with a subtle pulsing aura �?clicking
  ///     it stops the engine.
  ///   * **This bubble is paused** (`_ttsIsThisMessage && _ttsIsPaused`):
  ///     a `play_arrow` icon �?clicking it resumes (the same
  ///     `speak()` call becomes a toggle when the id matches).
  ///
  /// When `TtsService.isSupported` is `false` (Linux desktop,
  /// no-TTS-installed Android, browsers without `SpeechSynthesis`),
  /// the button is hidden entirely �?no point teasing an
  /// affordance that won't go anywhere.
  Widget _buildTtsSpeaker(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The cached `_ttsIsSupported` snapshot is the source of
    // truth for visibility. We don't read the service directly
    // here because `_lookupTts` would throw when called inside
    // `build` (the `BuildContext` is fine, but the `try/catch`
    // pattern we'd need to make it optional adds noise on the
    // hot path). The notifier listener registered in [initState]
    // keeps the snapshot up-to-date.
    if (!_ttsIsSupported) return const SizedBox.shrink();

    final IconData icon;
    final Color color;
    final String tooltip;
    if (_ttsIsThisMessage && !_ttsIsPaused) {
      icon = Icons.stop_rounded;
      // Same primary tint as the click-to-stop pulsing mic on the
      // chat input �?keeps the visual rhythm consistent across
      // the two recording-related affordances.
      color = AppTheme.primary;
      tooltip = l10n.chatTtsStop;
    } else if (_ttsIsThisMessage && _ttsIsPaused) {
      icon = Icons.play_arrow_rounded;
      color = AppTheme.primary;
      tooltip = l10n.chatTtsStop;
    } else {
      icon = Icons.volume_up_rounded;
      color = context.textSecondary;
      tooltip = l10n.chatTtsSpeak;
    }

    return Semantics(
      button: true,
      label: tooltip,
      // Tooltip child of the gesture surface �?we can't use the
      // [Tooltip] widget directly because that installs its own
      // [LongPressGestureRecognizer], which has been the source
      // of gesture-arena fights with the parent [Listener] in
      // the chat input. A 50% opaque pill background gives a
      // visual focus affordance without a [Tooltip] wrapper.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _onTtsSpeakerTapped(context),
        child: Container(
          width: 24,
          height: 24,
          margin: EdgeInsets.all(2.0),
          decoration: BoxDecoration(
            color: context.bubbleAssistant.withValues(alpha: 0.5),
            shape: BoxShape.circle,
            border: Border.all(color: context.appBorder, width: 0.5),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 15, color: color),
        ),
      ),
    );
  }

  /// Click handler. Three cases:
  ///
  ///   * **Idle** �?start speaking this bubble. The engine
  ///     starts on the bubble's raw `content`; `stts` handles
  ///     whatever string we hand it (markdown + newlines + code
  ///     fences are read as-is �?the user gets the literal text,
  ///     not the rendered markdown).
  ///   * **This bubble is speaking** �?stop.
  ///   * **This bubble is paused** �?resume (which the
  ///     `TtsService.speak(id, �?` API turns into a resume via
  ///     the toggle path; here we just delegate via [pause] /
  ///     [resume] for clarity).
  ///
  /// The `localeId` mirrors the chat-input voice-input
  /// selection: we read [AppLocalizations.localeName] (e.g. `'zh'`
  /// / `'en'`) and map it to a BCP-47 tag so the engine picks a
  /// voice that matches the user's app language. Without this the
  /// Windows SAPI default falls back to the system locale �?which
  /// is frequently wrong for our bilingual users.
  Future<void> _onTtsSpeakerTapped(BuildContext context) async {
    final tts = _lookupTts(context);
    if (tts == null) return;
    final l10n = AppLocalizations.of(context);
    final m = widget.message;
    if (_ttsIsThisMessage && !_ttsIsPaused) {
      await tts.stop();
      return;
    }
    if (_ttsIsThisMessage && _ttsIsPaused) {
      await tts.resume();
      return;
    }
    // Strip markdown formatting hints so the engine doesn't read
    // out raw `#`, `` ` ``, etc. The line-aware chunking matters
    // less for STT �?`stts.start()` accepts the whole string in
    // one go �?but trimmed / collapsed whitespace makes the
    // speech pause-map more natural on platforms that pause at
    // sentence boundaries.
    final cleaned = _stripMarkdownForSpeech(m.content);
    if (cleaned.trim().isEmpty) return;
    await tts.speak(
      m.id,
      cleaned,
      localeId: _localeIdForTtsSpeech(l10n.localeName),
    );
  }

  /// Map the app's canonicalized locale
  /// (`AppLocalizations.localeName`, e.g. `'en'`, `'zh'`) to a
  /// BCP-47 tag that `stts.Tts.setLanguage` passes through to the
  /// underlying voice engine (Android `TextToSpeech`,
  /// `AVSpeechSynthesizer` on iOS / macOS, SAPI on Windows,
  /// `SpeechSynthesis` on web). Returning `null` lets the engine
  /// keep its current voice.
  static String? _localeIdForTtsSpeech(String appLocale) {
    switch (appLocale) {
      case 'zh':
        return 'zh-CN';
      case 'en':
        return 'en-US';
      default:
        return null;
    }
  }

  /// Strip a minimum set of markdown / code-fence markers so the
  /// TTS engine reads the message naturally instead of spelling
  /// out `hash` / `backtick` for every inline code fragment. We
  /// intentionally do NOT touch fenced code blocks �?those are
  /// usually fine to read verbatim since users often ask the
  /// model to *write* code, and a TTS of the code body is more
  /// useful than silence.
  static String _stripMarkdownForSpeech(String input) {
    var s = input;
    // Drop fenced code block delimiters (```lang and ```), keep
    // the inner lines.
    s = s.replaceAll(RegExp(r'```\w*\n?'), '');
    s = s.replaceAll(RegExp(r'```\n?'), '');
    // Inline code: `foo` �?foo. `replaceAllMapped` is needed so
    // the captured group (`$1`-style substitution) actually
    // expands �?`replaceAll(..., String)` treats `$1` as a
    // literal token.
    s = s.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1) ?? '');
    // Heading hashes at line start.
    s = s.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
    // List bullets at line start: -, *, +, 1., 2., �?
    s = s.replaceAll(RegExp(r'^\s*(?:[-*+]|\d+\.)\s+', multiLine: true), '');
    // Bold (must come before italic so the `**` is consumed first,
    // leaving single-`*` for italic).
    s = s.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1) ?? '');
    // Single-`*` italic, anchored so it doesn't eat the `*` in
    // a `1 * 2` arithmetic expression.
    s = s.replaceAllMapped(
      RegExp(r'(?<!\*)\*([^*\n]+)\*(?!\*)'),
      (m) => m.group(1) ?? '',
    );
    // Collapse runs of 3+ blank lines.
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s;
  }

  /// Builds the right-aligned chip group (TTFT, decode-speed,
  /// total-token count) for the bubble's footer. Each chip is
  /// mapped to its l10n-aware format string via `AppLocalizations`
  /// (so "0.5s" vs "0.5�? etc. land naturally). The chip
  /// contents are derived from [MessageMetrics]:
  ///
  ///   * **TTFT** �?`Icons.schedule_outlined` + "<n>s" (or
  ///     "<m>m<ss>s" for �?60s), from `metrics.ttft`.
  ///   * **Decode speed** �?"<n>t/s" (tokens per second), from
  ///     `metrics.decodeTokensPerSecond`.
  ///   * **Total tokens** �?Σ + "<n> token", from
  ///     `metrics.inputTokens + metrics.outputTokens` (always
  ///     emitted as one number, e.g.
  ///     `Σ 1312 token`
  ///     where 1312 = input + output).
  ///
  /// Each chip is silently omitted when the underlying metric
  /// isn't available (still streaming, no tokens yet, etc.) so
  /// the footer never shows empty placeholders.
  List<Widget> _buildMetricChips(BuildContext context, MessageMetrics metrics) {
    final l10n = AppLocalizations.of(context);
    final secondary = context.textSecondary;
    final chipTextStyle = TextStyle(color: secondary, fontSize: 11);

    final chips = <Widget>[];

    final ttft = metrics.ttft;
    if (ttft != null) {
      chips.addAll([
        const SizedBox(width: 8),
        Icon(Icons.schedule_outlined, size: 12, color: secondary),
        const SizedBox(width: 2),
        Text(
          l10n.messageMetricTtft(_formatSeconds(ttft)),
          style: chipTextStyle,
        ),
      ]);
    }

    final tps = metrics.tokensPerSecond;
    if (tps != null && tps > 0) {
      chips.addAll([
        const SizedBox(width: 8),
        Text(
          l10n.messageMetricSpeed(tps.toStringAsFixed(tps >= 100 ? 0 : 1)),
          style: chipTextStyle,
        ),
      ]);
    }

    // Total token count for this turn (input + output). Sits
    // at the far right of the footer, prefixed with a Σ glyph
    // to distinguish it from the per-second throughput
    // immediately to its left. When the model emitted zero
    // tokens (errors before first chunk, pure-tool-call turn
    // with no text, �? we skip the chip entirely.
    final total = metrics.inputTokens + metrics.outputTokens;
    if (total > 0) {
      chips.addAll([
        const SizedBox(width: 8),
        Text('Σ', style: chipTextStyle),
        const SizedBox(width: 2),
        Text(
          l10n.messageMetricTokensTotal(total.toString()),
          style: chipTextStyle,
        ),
      ]);
    }

    return chips;
  }

  /// Formats a [Duration] as a localized short string: "0.50s",
  /// "12.3s", "1m05s". Mirrors the convention requested in the
  /// task ("0.50s") but rounds up to seconds once the value
  /// passes 60s so the footer doesn't grow unbounded.
  static String _formatSeconds(Duration d) {
    if (d.inSeconds < 60) {
      // Always show two decimals so the user can read "0.50s"
      // vs "0.05s" at a glance �?the small TTFT case is the
      // most informative one for cache-hit comparisons.
      return '${(d.inMicroseconds / 1000000).toStringAsFixed(2)}s';
    }
    final mins = d.inMinutes;
    final secs = d.inSeconds - mins * 60;
    return '${mins}m${secs.toString().padLeft(2, '0')}s';
  }

  Widget _buildToolCalls(BuildContext context, List<ToolCall> calls) {
    final chat = context.read<ChatProvider>();
    final assistantId = widget.message.id;
    final keys = MessageBubble.disambiguateToolCallKeys(calls);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < calls.length; i++) ...[
          _ToolCallCard(
            key: ValueKey(keys[i]),
            toolCall: calls[i],
            assistantId: assistantId,
            onRetry: calls[i].isFailed
                ? () => chat.retryToolCall(context, assistantId, calls[i].id)
                : null,
          ),
          SizedBox(height: 6),
        ],
      ],
    );
  }

  /// Renders one `_AskUserQuestionCard` per pending ask_user tool
  /// call on this assistant message. Sits at the bottom of the
  /// bubble (below the content + footer) so the user can't miss
  /// the question — previously the chips lived inside the tool
  /// call section, which is collapsed by default and felt like
  /// an internal implementation detail.
  Widget _buildAskUserQuestions(BuildContext context, ChatMessage m) {
    // Cheap pre-check — defer the [ChatProvider] lookup until we
    // know there's at least one ask_user to render, so messages
    // without any pending question don't trip widget tests that
    // don't mount the provider (and the bare `context.read`
    // call doesn't run on every unrelated rebuild).
    final asks = <ToolCall>[];
    for (final tc in m.toolCalls) {
      if (tc.question != null && tc.options != null) {
        asks.add(tc);
      }
    }
    if (asks.isEmpty) return const SizedBox.shrink();
    // Same graceful fallback as `_lookupTts`: production always
    // supplies `Provider<ChatProvider>` via `main.dart`, but
    // legacy bubble widget tests pre-date this code path, and
    // surfacing an uncaught "no provider" exception would defeat
    // the whole point of the pre-check above. Without the
    // provider we can't dispatch taps back to the chat session,
    // so suppress the card entirely.
    final ChatProvider chat;
    try {
      chat = context.read<ChatProvider>();
    } catch (_) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < asks.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _AskUserQuestionCard(
              key: ValueKey('ask_user_${asks[i].id}'),
              toolCall: asks[i],
              onSubmit: (selection) {
                chat.resolveAskUser(asks[i].id, selection);
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Renders a collapsed group of consecutive tool-role messages.
/// Shows a summary badge ("调用�?N 个工�?) that expands to reveal
/// each individual tool call card.
class _GroupedToolCalls extends StatefulWidget {
  const _GroupedToolCalls({
    required this.messages,
    required this.allCalls,
    required this.onCopy,
  });

  final List<ChatMessage> messages;
  final List<ToolCall> allCalls;
  final ValueChanged<String> onCopy;

  @override
  State<_GroupedToolCalls> createState() => _GroupedToolCallsState();
}

class _GroupedToolCallsState extends State<_GroupedToolCalls> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final count = widget.allCalls.length;
    final successCount = widget.allCalls
        .where((c) => c.status == ToolCallStatus.success)
        .length;
    final failedCount = widget.allCalls
        .where((c) => c.status == ToolCallStatus.failed)
        .length;
    final runningCount = widget.allCalls
        .where((c) => c.status == ToolCallStatus.running)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              color: context.toolCallBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.toolCallBorder),
            ),
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.build_outlined,
                      size: 14,
                      color: context.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.toolGroupSummary(count),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (runningCount > 0)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          valueColor: AlwaysStoppedAnimation(AppTheme.primary),
                        ),
                      )
                    else ...[
                      if (failedCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Text(
                            '$failedCount/$count',
                            style: TextStyle(
                              fontSize: 11,
                              color: context.errorText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      if (successCount == count)
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 14,
                          color: const Color(0xFF1F883D),
                        ),
                    ],
                    const SizedBox(width: 4),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: context.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            for (final m in widget.messages) ...[
              if (m.toolCalls.isNotEmpty) _buildToolCalls(context, m.toolCalls),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildToolCalls(BuildContext context, List<ToolCall> calls) {
    final keys = MessageBubble.disambiguateToolCallKeys(calls);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < calls.length; i++) ...[
          _ToolCallCard(
            key: ValueKey(keys[i]),
            toolCall: calls[i],
            assistantId: '',
            onRetry: null,
          ),
          SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({
    super.key,
    required this.toolCall,
    required this.assistantId,
    this.onRetry,
  });

  final ToolCall toolCall;
  // id of the assistant [ChatMessage] that owns this tool call.
  // The download card needs it so the chat provider can route
  // "save" / "discard" / "cancel" actions back to the right
  // tool call. Captured here (not read via Provider) so the
  // download card is testable in isolation.
  final String assistantId;
  final VoidCallback? onRetry;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  Color _statusColor(ToolCallStatus s) {
    switch (s) {
      case ToolCallStatus.pending:
        return const Color(0xFF8B949E);
      case ToolCallStatus.running:
        return AppTheme.primary;
      case ToolCallStatus.success:
        return const Color(0xFF1F883D);
      case ToolCallStatus.failed:
        return const Color(0xFFD1242F);
    }
  }

  IconData _statusIcon(ToolCallStatus s) {
    switch (s) {
      case ToolCallStatus.pending:
        return Icons.schedule_outlined;
      case ToolCallStatus.running:
        return Icons.hourglass_top_rounded;
      case ToolCallStatus.success:
        return Icons.check_circle_outline_rounded;
      case ToolCallStatus.failed:
        return Icons.error_outline_rounded;
    }
  }

  String _formatDuration(Duration d) {
    final l10n = AppLocalizations.of(context);
    if (d.inSeconds < 1) return l10n.toolCallDurationMs(d.inMilliseconds);
    return l10n.toolCallDurationSec(d.inSeconds.toString());
  }

  @override
  Widget build(BuildContext context) {
    final tc = widget.toolCall;
    final isSubAgent = tc.name == 'subagent';
    final l10n = AppLocalizations.of(context);
    final color = _statusColor(tc.status);
    final icon = _statusIcon(tc.status);

    final statusText = switch (tc.status) {
      ToolCallStatus.pending => l10n.toolCallStatusPending,
      ToolCallStatus.running => l10n.toolCallStatusRunning,
      ToolCallStatus.success => l10n.toolCallStatusSuccess,
      ToolCallStatus.failed => l10n.toolCallStatusFailed,
    };

    return Container(
      decoration: BoxDecoration(
        color: context.toolCallBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.toolCallBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  if (tc.status == ToolCallStatus.running)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    )
                  else
                    Icon(icon, size: 14, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isSubAgent ? '子 Agent' : tc.name,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (tc.isDone && tc.duration != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      _formatDuration(tc.duration!),
                      style: TextStyle(
                        fontSize: 11,
                        color: context.textSecondary,
                      ),
                    ),
                  ],
                  if (widget.onRetry != null && tc.isFailed) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: l10n.toolCallRetryFailed,
                      child: InkWell(
                        onTap: widget.onRetry,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.refresh_rounded,
                            size: 14,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ],
                  SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: color,
                  ),
                ],
              ),
            ),
          ),
          if (tc.awaitingUserAction && tc.isRunning)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.touch_app_outlined,
                    size: 13,
                    color: context.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      l10n.toolCallAwaitingUser,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (isSubAgent && _expanded && (tc.result ?? '').trim().isNotEmpty)
            _buildSubAgentResult(context, tc)
          else if (!isSubAgent && (_expanded || tc.downloads.isNotEmpty))
            _buildDetails(context, tc, l10n),
        ],
      ),
    );
  }

  /// Max height for the tool-call arguments / result code blocks.
  /// Tall enough to show ~24 lines of monospace text; beyond that,
  /// the block becomes internally scrollable. Without a hard cap the
  /// bubbles grow without bound for long tool results (a 30KB page
  /// fetch would push everything else off-screen).
  static const double _detailsMaxHeight = 320;

  Widget _buildSubAgentResult(BuildContext context, ToolCall tc) {
    final result = tc.result!.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: context.appBorder),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: _detailsMaxHeight),
            decoration: BoxDecoration(
              color: tc.isFailed ? context.errorBg : context.codeBlockBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: tc.isFailed
                    ? context.errorBorder
                    : context.codeBlockBorder,
              ),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(6),
              child: Text(
                result,
                style: TextStyle(
                  fontSize: 11,
                  color: tc.isFailed ? context.errorText : context.textPrimary,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetails(
    BuildContext context,
    ToolCall tc,
    AppLocalizations l10n,
  ) {
    final hasArgs = tc.arguments.trim().isNotEmpty;
    final hasDownloads = tc.downloads.isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasDownloads) ...[
            Divider(height: 1, color: context.appBorder),
            const SizedBox(height: 6),
            for (final d in tc.downloads)
              DownloadCard(
                key: ValueKey('download_${d.id}'),
                item: d,
                assistantId: widget.assistantId,
                toolId: tc.id,
              ),
          ],
          if (_expanded) ...[
            if (hasArgs) ...[
              Divider(height: 1, color: context.appBorder),
              SizedBox(height: 6),
              Text(
                l10n.toolCallArguments,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
              SizedBox(height: 4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: _detailsMaxHeight),
                decoration: BoxDecoration(
                  color: context.codeBlockBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: context.codeBlockBorder),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    hasArgs
                        ? _prettyJson(tc.arguments)
                        : l10n.toolCallNoArguments,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: context.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
            if (tc.isDone) ...[
              SizedBox(height: 8),
              Text(
                l10n.toolCallResult,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: tc.isFailed
                      ? context.errorText
                      : context.textSecondary,
                ),
              ),
              SizedBox(height: 4),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: _detailsMaxHeight),
                decoration: BoxDecoration(
                  color: tc.isFailed ? context.errorBg : context.codeBlockBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: tc.isFailed
                        ? context.errorBorder
                        : context.codeBlockBorder,
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    (tc.result ?? '').isEmpty
                        ? l10n.toolCallNoResult
                        : tc.result!,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: tc.isFailed
                          ? context.errorText
                          : context.textPrimary,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _prettyJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      final decoded = jsonDecode(trimmed);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return trimmed;
    }
  }
}

/// Renders markdown, with throttled re-render while [streaming] is true to
/// avoid re-parsing the entire block on every token during AI streaming,
/// then animates the visible character count up to the latest snapshot to
/// produce a typewriter feel.
class _StreamingMarkdown extends StatefulWidget {
  const _StreamingMarkdown({required this.data, required this.streaming});

  final String data;
  final bool streaming;

  @override
  State<_StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<_StreamingMarkdown>
    with SingleTickerProviderStateMixin {
  String _rendered = '';
  Timer? _throttle;
  // Eagerly initialized in [initState] rather than as a `late final`
  // field. The late-initializer form would only run on first access
  // �?and if the widget is disposed before any tick fires (e.g. the
  // assistant message stops streaming immediately, so
  // [_animateTo] is never called, and the message bubble is then
  // unmounted by a session switch), the first access lands in
  // [dispose] while the element is already inactive. That trips
  // `AnimationController`'s `TickerMode` lookup against a
  // deactivated element, which throws "Looking up a deactivated
  // widget's ancestor is unsafe".
  late final AnimationController _typewriter;
  int _visibleLength = 0;

  static const Duration _smallDeltaDelay = Duration(milliseconds: 120);
  static const int _smallDeltaInstantChars = 64;
  static const int _typewriterCharsPerSecond = 30;

  @override
  void initState() {
    super.initState();
    _rendered = widget.data;
    _visibleLength = _rendered.length;
    _typewriter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16),
    )..addListener(_onTypewriterTick);
  }

  @override
  void didUpdateWidget(covariant _StreamingMarkdown old) {
    super.didUpdateWidget(old);
    if (!widget.streaming) {
      _throttle?.cancel();
      _typewriter.stop();
      _rendered = widget.data;
      _visibleLength = _rendered.length;
      return;
    }
    final delta = widget.data.length - _rendered.length;
    if (delta > _smallDeltaInstantChars) {
      _throttle?.cancel();
      _rendered = widget.data;
      _animateTo(_rendered.length);
    } else {
      _throttle?.cancel();
      _throttle = Timer(_smallDeltaDelay, () {
        if (!mounted) return;
        setState(() {
          _rendered = widget.data;
          _animateTo(_rendered.length);
        });
      });
    }
  }

  void _animateTo(int target) {
    final remaining = target - _visibleLength;
    if (remaining <= 0) {
      _visibleLength = target;
      return;
    }
    _startLengthForTick = _visibleLength;
    _endLengthForTick = target;
    final ms = (remaining * 1000 / _typewriterCharsPerSecond)
        .clamp(60, 800)
        .toInt();
    _typewriter
      ..stop()
      ..duration = Duration(milliseconds: ms)
      ..value = 0;
    _typewriter.forward();
  }

  void _onTypewriterTick() {
    if (!mounted) return;
    setState(() {
      final t = _typewriter.value;
      _visibleLength =
          (_startLengthForTick + t * (_endLengthForTick - _startLengthForTick))
              .round()
              .clamp(0, _rendered.length);
    });
  }

  int _startLengthForTick = 0;
  int _endLengthForTick = 0;

  @override
  void dispose() {
    _throttle?.cancel();
    _typewriter.dispose();
    super.dispose();
  }

  static int _safeSubstringEnd(String s, int end) {
    if (end <= 0 || end >= s.length) return end;
    final cu = s.codeUnitAt(end - 1);
    if (cu >= 0xD800 && cu <= 0xDBFF) return end - 1;
    return end;
  }

  @override
  Widget build(BuildContext context) {
    final safeLength = _safeSubstringEnd(_rendered, _visibleLength);
    final visible = _rendered.substring(0, safeLength);
    final text = visible.isEmpty ? ' ' : visible;
    // The streaming typewriter advances `_visibleLength` only
    // every ~33ms (driven by the AnimationController). Wrapping
    // the markdown in `AnimatedSize` would re-run a layout
    // animation on every advance �?that animation drives a
    // global relayout of the parent ListView, which is one of
    // the main causes of scroll jank during streaming. We drop
    // the AnimatedSize entirely: each tick the parent gets a
    // new `_visibleLength`, the column grows by one line, and
    // ListView's intrinsic size update is a single tick, not an
    // interpolated animation.
    return RepaintBoundary(
      // Keep the streaming widget's repaints from rippling into
      // the parent Column.
      child: MarkdownContent(data: text),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator();

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  // Eagerly initialized in [initState] (not `late final` with an
  // initializer) so the AnimationController is created while the
  // element is still active. See [_StreamingMarkdownState] for the
  // full reason; in short: this widget's field is never read
  // before [dispose] runs, which would otherwise let the late
  // initializer fire inside an inactive context.
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final t = (_c.value + i * 0.2) % 1.0;
              final opacity =
                  0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: opacity),
                  shape: BoxShape.circle,
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// Renders the model’s question and its option chips at the
/// bottom of an assistant message bubble. Tapping a chip
/// (single-select) or tapping Confirm (multi-select) hands the
/// selection to [ChatProvider.resolveAskUser], which unblocks
/// the orchestrator’s `await` on the tool call.
///
/// Previously this widget lived inside the (default-collapsed)
/// tool call section, which made the question easy to miss.
/// Now it sits below the bubble + footer so the user always
/// notices that the model is asking them to choose.
class _AskUserQuestionCard extends StatefulWidget {
  const _AskUserQuestionCard({
    super.key,
    required this.toolCall,
    required this.onSubmit,
  });

  final ToolCall toolCall;
  final ValueChanged<String> onSubmit;

  @override
  State<_AskUserQuestionCard> createState() => _AskUserQuestionCardState();
}

class _AskUserQuestionCardState extends State<_AskUserQuestionCard> {
  final Set<String> _localSelected = <String>{};
  bool _submitted = false;

  /// Coerce the persisted ask_user options list to `List<String>`.
  /// New tool calls already arrive normalized (see
  /// `ChatProvider._normalizeAskUserOptions`); this fallback exists
  /// for sessions written by older app versions where each option
  /// was an object like `{"label": "A"}` and would otherwise crash
  /// the chip Wrap with a Map→String cast. Returns `const []` when
  /// the input is null or empty.
  static List<String> _coerceOptions(List<dynamic>? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final out = <String>[];
    for (final entry in raw) {
      if (entry is String) {
        if (entry.isNotEmpty) out.add(entry);
      } else if (entry is Map) {
        for (final key in const ['label', 'value', 'text']) {
          final v = entry[key];
          if (v is String && v.isNotEmpty) {
            out.add(v);
            break;
          }
        }
      }
    }
    return out;
  }

  bool get _isMulti => widget.toolCall.multiSelect ?? false;

  bool get _isInteractive =>
      widget.toolCall.status == ToolCallStatus.running && !_submitted;

  /// Once the tool call has succeeded, derive the final pick(s) from
  /// the persisted result JSON. While still running, fall back to the
  /// in-progress multi-select state.
  Set<String> get _effectiveSelected {
    if (widget.toolCall.status == ToolCallStatus.success) {
      return _parseSelection(widget.toolCall.result ?? '');
    }
    return _localSelected;
  }

  void _onPick(String option) {
    if (!_isInteractive) return;
    if (_isMulti) {
      setState(() {
        if (_localSelected.contains(option)) {
          _localSelected.remove(option);
        } else {
          _localSelected.add(option);
        }
      });
    } else {
      setState(() => _submitted = true);
      widget.onSubmit(jsonEncode({'selection': option}));
    }
  }

  void _submitMulti() {
    if (_localSelected.isEmpty) return;
    setState(() => _submitted = true);
    widget.onSubmit(jsonEncode({'selection': _localSelected.toList()}));
  }

  static Set<String> _parseSelection(String result) {
    try {
      final decoded = jsonDecode(result);
      if (decoded is Map && decoded['selection'] != null) {
        final sel = decoded['selection'];
        if (sel is String) return {sel};
        if (sel is List) return sel.map((e) => e.toString()).toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final selected = _effectiveSelected;
    // Defensive: if a stale ToolCall (persisted before the
    // ask_user options normalizer existed) loaded from disk has
    // object-shaped entries, `for (final opt in options)` would
    // throw `type 'Map<String, dynamic>' is not a subtype of
    // type 'String' in type cast` mid-render. Coerce eagerly
    // here so the bubble never crashes on a non-string entry;
    // new tool calls go through `_normalizeAskUserOptions` in
    // ChatProvider._onToolCall and arrive as `List<String>`.
    final options = _coerceOptions(widget.toolCall.options);
    final question = widget.toolCall.question ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: context.bubbleAssistant,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        border: Border.all(color: context.appBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: "模型询问:" / "Model asks:" — makes it
          // obvious the user is being prompted, since this card
          // now sits below the bubble (outside the tool call
          // block) and could otherwise look like a stray UI.
          Row(
            children: [
              Icon(
                Icons.help_outline_rounded,
                size: 13,
                color: context.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                l10n.askUserQuestionPrompt,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ],
          ),
          if (question.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              question,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: context.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (options.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final opt in options)
                  _OptionChip(
                    label: opt,
                    selected: selected.contains(opt),
                    enabled: _isInteractive,
                    onTap: () => _onPick(opt),
                  ),
              ],
            ),
            if (_isMulti && _isInteractive) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _localSelected.isEmpty ? null : _submitMulti,
                  child: Text(l10n.commonConfirm),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (!enabled) {
      bg = selected ? AppTheme.primary.withValues(alpha: 0.45) : context.bg;
      fg = selected ? Colors.white : context.textSecondary;
    } else {
      bg = selected ? AppTheme.primary : context.surface;
      fg = selected ? Colors.white : context.textPrimary;
    }
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? AppTheme.primary : context.appBorder,
        ),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check_rounded, size: 14, color: fg),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Carries the [ToolCall.id] alongside each [EditedImage] so
/// the gallery can route the user's Save tap back to the
/// right tool call via `ChatProvider.saveEditedImage(...)`.
/// Internal-only — defined at the bottom of this file because
/// it's a 1:1 view-model for the gallery section above.
class _EditedImageEntry {
  const _EditedImageEntry({required this.toolId, required this.image});
  final String toolId;
  final EditedImage image;
}
