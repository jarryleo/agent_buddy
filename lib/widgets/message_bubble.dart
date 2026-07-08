import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../models/message.dart';
import '../theme/app_theme.dart';
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
  static const int _thinkingCollapsedLines = 5;
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
    final atBottom = pos.pixels >= pos.maxScrollExtent - _autoScrollBottomTolerance;
    if (atBottom != _thinkingAtBottom) {
      _thinkingAtBottom = atBottom;
    }
  }

  void _maybeAutoScrollThinking() {
    if (!_thinkingAtBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_thinkingScroll.hasClients) return;
      final pos = _thinkingScroll.position;
      if (pos.pixels >= pos.maxScrollExtent - _autoScrollBottomTolerance) {
        _thinkingScroll.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    if (m.role == MessageRole.user) {
      return _buildUser(context, m);
    }
    final maxLines = _thinkingExpanded ? _thinkingExpandedLines : _thinkingCollapsedLines;
    final thinkingChanged = m.thinking != _lastThinking;
    final expandedChanged = maxLines != _lastExpandedLines;
    if (thinkingChanged || expandedChanged) {
      _lastThinking = m.thinking;
      _lastExpandedLines = maxLines;
      _maybeAutoScrollThinking();
    }
    return _buildAssistant(context, m);
  }

  Widget _buildUser(BuildContext context, ChatMessage m) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 4, 12, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.bubbleUser,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Text(
                m.content,
                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssistant(BuildContext context, ChatMessage m) {
    final hasThinking = m.thinking.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 48, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasThinking) _buildThinking(context, m),
          if (m.content.isNotEmpty || m.streaming)
            Container(
              margin: EdgeInsets.only(top: hasThinking ? 6 : 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.bubbleAssistant,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                border: Border.all(color: AppTheme.border),
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
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                  ),
                ),
                if (m.content.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => widget.onCopy(m.content),
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.copy_rounded, size: 12, color: AppTheme.textSecondary),
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
    final maxLines = _thinkingExpanded ? _thinkingExpandedLines : _thinkingCollapsedLines;
    final overflow = lineCount > maxLines;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.thinking,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEED79B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: overflow ? () => setState(() => _thinkingExpanded = !_thinkingExpanded) : null,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.psychology_outlined, size: 14, color: Color(0xFFA37300)),
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
                  if (overflow)
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
}

/// Renders markdown, with throttled re-render while [streaming] is true to
/// avoid re-parsing the entire block on every token during AI streaming.
class _StreamingMarkdown extends StatefulWidget {
  const _StreamingMarkdown({required this.data, required this.streaming});

  final String data;
  final bool streaming;

  @override
  State<_StreamingMarkdown> createState() => _StreamingMarkdownState();
}

class _StreamingMarkdownState extends State<_StreamingMarkdown> {
  String _rendered = '';
  Timer? _throttle;

  @override
  void initState() {
    super.initState();
    _rendered = widget.data;
  }

  @override
  void didUpdateWidget(covariant _StreamingMarkdown old) {
    super.didUpdateWidget(old);
    if (!widget.streaming) {
      _throttle?.cancel();
      _rendered = widget.data;
      return;
    }
    final delta = widget.data.length - _rendered.length;
    if (delta > 64) {
      // Big update, render immediately so the user sees progress.
      _throttle?.cancel();
      _rendered = widget.data;
    } else {
      _throttle?.cancel();
      _throttle = Timer(const Duration(milliseconds: 120), () {
        if (!mounted) return;
        setState(() => _rendered = widget.data);
      });
    }
  }

  @override
  void dispose() {
    _throttle?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _rendered.isEmpty ? ' ' : _rendered;
    return AnimatedSize(
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
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
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
        ..repeat();

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
              final opacity = 0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
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
