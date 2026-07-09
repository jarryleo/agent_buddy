import 'package:flutter/material.dart';

class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child, this.maxWidth = 480});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final isWide = width > maxWidth + 32;
        final isTall = constraints.maxHeight > maxWidth * 2.2;
        final showFrame = isWide || isTall;
        return Container(
          color: const Color(0xFFE9ECF1),
          child: Center(
            child: showFrame
                ? _buildPhoneContainer(context, constraints)
                : ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: child,
                  ),
          ),
        );
      },
    );
  }

  Widget _buildPhoneContainer(
    BuildContext context,
    BoxConstraints constraints,
  ) {
    final width = maxWidth.clamp(320.0, 440.0);
    final ratio = constraints.maxHeight / constraints.maxWidth;
    double height;
    if (ratio > 2.0) {
      height = width * 2.0;
    } else {
      height = constraints.maxHeight - 32;
    }
    return Container(
      width: width,
      height: height,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(44),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 30,
            offset: Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: Stack(
          children: [
            Positioned.fill(child: child),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 120,
                  height: 26,
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
