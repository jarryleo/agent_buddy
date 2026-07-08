import 'package:flutter/material.dart';

/// Wraps an [IconButton] with a [Focus] that has `canRequestFocus: false`.
///
/// This prevents the button from being part of the focus traversal on desktop,
/// which works around a Flutter framework assertion that fires when the
/// button's internal Focus node re-dispatches a `KeyDownEvent` for an already
/// pressed physical key (commonly triggered on Windows when the keyboard
/// layout / IME sends auto-repeat events for modifier keys like Shift).
///
/// See: `HardwareKeyboard._dispatchKeyEvent` debug assertion.
class NoFocusIconButton extends StatelessWidget {
  const NoFocusIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      descendantsAreFocusable: false,
      child: IconButton(
        icon: icon,
        onPressed: onPressed,
        tooltip: tooltip,
        color: color,
      ),
    );
  }
}
