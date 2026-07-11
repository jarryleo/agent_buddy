import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Constrains [child] to a phone-width column, centered on wide screens.
///
/// On narrow viewports the child fills the available width; on wider
/// viewports the content is clamped to [maxWidth] and centered so the
/// layout always reads as a phone-sized column. The surrounding area
/// uses the active theme's background so the column blends seamlessly
/// in both light and dark mode.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({super.key, required this.child, this.maxWidth = 480});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}
