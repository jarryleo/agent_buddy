import 'dart:async';

import 'package:flutter/material.dart';

class PetSpeechBubble extends StatefulWidget {
  const PetSpeechBubble({
    super.key,
    required this.text,
    required this.visible,
    this.fadeDuration = const Duration(milliseconds: 220),
  });

  final String text;

  /// Whether the bubble should currently be shown. Decoupled from
  /// [text] so the parent can fade the bubble out in place before
  /// changing [text] to empty, and so an empty initial state still
  /// has a defined opacity (0) instead of being rendered as a hidden
  /// placeholder that has to be swapped in the layout tree.
  final bool visible;

  /// How long the opacity 0↔1 transition takes. Picked so that the
  /// pet window's post-fade resize can run after the transition
  /// completes without making the auto-hide feel laggy.
  final Duration fadeDuration;

  @override
  State<PetSpeechBubble> createState() => _PetSpeechBubbleState();
}

class _PetSpeechBubbleState extends State<PetSpeechBubble> {
  final ScrollController _scrollController = ScrollController();
  Timer? _scrollTimer;

  @override
  void didUpdateWidget(covariant PetSpeechBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text) return;
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 16), () {
      if (!_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = widget.text.trim().isNotEmpty;
    final shouldShow = widget.visible && hasText;
    // The bubble never "flashes downward" — the same layout is held
    // in the tree at the bubble's slot regardless of `visible`, and
    // the visibility transition is a pure opacity animation. The
    // pet window separately defers its bottom-anchored resize until
    // *after* this transition completes so the OS-level window
    // doesn't re-anchor its top edge downward while the bubble is
    // mid-fade.
    return IgnorePointer(
      ignoring: !shouldShow,
      child: AnimatedOpacity(
        opacity: shouldShow ? 1.0 : 0.0,
        duration: widget.fadeDuration,
        curve: Curves.easeOutCubic,
        child: hasText ? _buildBubble() : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildBubble() {
    return Align(
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 44, maxHeight: 66),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x33000000)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            // `Scrollbar(thumbVisibility: false)` keeps the scroll-to-bottom
            // affordance while permanently hiding the scrollbar thumb (on
            // desktop / web Flutter would otherwise show it; on mobile the
            // widget is a no-op so this is safe across all platforms).
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: false,
              child: SingleChildScrollView(
                controller: _scrollController,
                child: Text(
                  widget.text,
                  style: const TextStyle(
                    color: Color(0xFF222222),
                    fontSize: 12,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ),
          CustomPaint(size: const Size(14, 8), painter: _BubbleTailPainter()),
        ],
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
