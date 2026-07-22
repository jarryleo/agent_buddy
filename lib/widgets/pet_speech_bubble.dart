import 'dart:async';

import 'package:flutter/material.dart';

class PetSpeechBubble extends StatefulWidget {
  const PetSpeechBubble({super.key, required this.text});

  final String text;

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
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 44, maxHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
