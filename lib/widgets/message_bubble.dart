import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/message.dart';
import '../providers/chat_provider.dart';
import '../theme/app_theme.dart';
import 'image_preview.dart';
import 'download_card.dart';
import 'markdown_content.dart';

class MessageBubble extends StatefulWidget {
  const MessageBubble({super.key, required this.message, required this.onCopy});

  final ChatMessage message;
  final ValueChanged<String> onCopy;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _thinkingExpanded = false;
  static const int _thinkingCollapsedLines = 3;
  static const int _thinkingExpandedLines = 10;
  static const double _autoScrollBottomTolerance = 24;

  final ScrollController _thinkingScroll = ScrollController();
  bool _thinkingAtBottom = true;
  String _lastThinking = '';
  int _lastExpandedLines = _thinkingCollapsedLines;

  @override
  void initState() {
    super.initState();
    _thinkingScroll.addListener(_onThinkingScroll);
  }

  @override
  void dispose() {
    _thinkingScroll.removeListener(_onThinkingScroll);
    _thinkingScroll.dispose();
    super.dispose();
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
    // ListView.builder already does for free — but the explicit
    // RepaintBoundary also stops a Paint pass from re-rasterizing
    // sibling messages when the streaming layer grows).
    return RepaintBoundary(child: body);
  }

  Widget _buildUser(BuildContext context, ChatMessage m) {
    final hasImages = m.imagePaths.isNotEmpty;
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
                if (hasImages && m.content.isNotEmpty)
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserImages(BuildContext context, List<String> paths) {
    final maxWidth = MediaQuery.of(context).size.width * 0.65;
    final thumbSize = paths.length == 1 ? 160.0 : 88.0;
    // Match the device pixel ratio so we don't upload a 4x larger
    // image than the thumbnail actually needs. The Image.file
    // engine will downscale to these cache dimensions once at
    // decode time, then keep the scaled pixels in the image
    // cache. Without this, every chat-list rebuild re-decodes
    // the full-resolution photo and re-uploads it to the GPU.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (thumbSize * dpr).round();
    final crossAxisCount = paths.length == 1
        ? 1
        : (paths.length >= 3 ? 2 : paths.length);
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
                child: Image.file(
                  File(path),
                  width: thumbSize,
                  height: thumbSize,
                  fit: BoxFit.cover,
                  cacheWidth: cacheSize,
                  cacheHeight: cacheSize,
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

  Widget _buildAssistant(BuildContext context, ChatMessage m) {
    final hasThinking = m.thinking.isNotEmpty;
    final hasTools = m.toolCalls.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasThinking) _buildThinking(context, m),
          if (hasTools) _buildToolCalls(context, m.toolCalls),
          if (m.content.isNotEmpty || m.streaming)
            Container(
              margin: EdgeInsets.only(top: (hasThinking || hasTools) ? 6 : 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  _StreamingMarkdown(data: m.content, streaming: m.streaming),
                  if (m.streaming) const _TypingIndicator(),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('HH:mm').format(m.createdAt.toLocal()),
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                ),
                if (m.content.isNotEmpty) ...[
                  SizedBox(width: 6),
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
              ],
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
    // Toggle is available when:
    //  - collapsed and the content doesn't fit (▼ to expand), or
    //  - expanded (▲ to collapse, even if the content already fits in
    //    the expanded view). Without this second clause, the user
    //    can't collapse once expanded if lineCount <= expanded limit.
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

  Widget _buildToolCalls(BuildContext context, List<ToolCall> calls) {
    final chat = context.read<ChatProvider>();
    final assistantId = widget.message.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final tc in calls) ...[
          _ToolCallCard(
            key: ValueKey('tool_${tc.id}'),
            toolCall: tc,
            assistantId: assistantId,
            onRetry: tc.isFailed
                ? () => chat.retryToolCall(context, assistantId, tc.id)
                : null,
          ),
          if (tc.question != null && tc.options != null) ...[
            const SizedBox(height: 4),
            _AskUserOptions(
              key: ValueKey('ask_user_${tc.id}'),
              toolCall: tc,
              onSubmit: (selection) {
                chat.resolveAskUser(tc.id, selection);
              },
            ),
          ],
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
                      tc.name,
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
          if (_expanded || tc.downloads.isNotEmpty)
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
                child: Scrollbar(
                  thumbVisibility: false,
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
                child: Scrollbar(
                  thumbVisibility: false,
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
  // — and if the widget is disposed before any tick fires (e.g. the
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

  @override
  Widget build(BuildContext context) {
    final visible = _rendered.substring(0, _visibleLength);
    final text = visible.isEmpty ? ' ' : visible;
    // The streaming typewriter advances `_visibleLength` only
    // every ~33ms (driven by the AnimationController). Wrapping
    // the markdown in `AnimatedSize` would re-run a layout
    // animation on every advance — that animation drives a
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

/// Inline option chips rendered below an `ask_user` tool call card.
/// Tapping a chip (single-select) or tapping Confirm (multi-select)
/// hands the selection to [ChatProvider.resolveAskUser], which
/// unblocks the SSE stream's `await` on the tool call.
class _AskUserOptions extends StatefulWidget {
  const _AskUserOptions({
    super.key,
    required this.toolCall,
    required this.onSubmit,
  });

  final ToolCall toolCall;
  final ValueChanged<String> onSubmit;

  @override
  State<_AskUserOptions> createState() => _AskUserOptionsState();
}

class _AskUserOptionsState extends State<_AskUserOptions> {
  final Set<String> _localSelected = <String>{};
  bool _submitted = false;

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
    final options = widget.toolCall.options ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
