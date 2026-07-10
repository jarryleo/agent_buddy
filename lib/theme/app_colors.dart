import 'package:flutter/material.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.border,
    required this.bubbleUser,
    required this.bubbleAssistant,
    required this.thinking,
    required this.thinkingAccent,
    required this.thinkingBorder,
    required this.thinkingText,
    required this.toolCallBg,
    required this.toolCallBorder,
    required this.codeBlockBg,
    required this.codeBlockBorder,
    required this.errorBg,
    required this.errorBorder,
    required this.errorText,
  });

  final Color bg;
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final Color border;
  final Color bubbleUser;
  final Color bubbleAssistant;
  final Color thinking;
  final Color thinkingAccent;
  final Color thinkingBorder;
  final Color thinkingText;
  final Color toolCallBg;
  final Color toolCallBorder;
  final Color codeBlockBg;
  final Color codeBlockBorder;
  final Color errorBg;
  final Color errorBorder;
  final Color errorText;

  static const AppColors light = AppColors(
    bg: Color(0xFFF6F7F9),
    surface: Colors.white,
    textPrimary: Color(0xFF1A1A1A),
    textSecondary: Color(0xFF6E6E73),
    border: Color(0xFFE5E5EA),
    bubbleUser: Color(0xFF1F6FEB),
    bubbleAssistant: Color(0xFFFFFFFF),
    thinking: Color(0xFFFFF7E0),
    thinkingAccent: Color(0xFF8A5C00),
    thinkingBorder: Color(0xFFEED79B),
    thinkingText: Color(0xFF6B4A00),
    toolCallBg: Color(0xFFF6F8FA),
    toolCallBorder: Color(0xFFE5E5EA),
    codeBlockBg: Color(0xFFF6F8FA),
    codeBlockBorder: Color(0xFFE5E5EA),
    errorBg: Color(0xFFFFF5F5),
    errorBorder: Color(0xFFFFC1C1),
    errorText: Color(0xFF8B0000),
  );

  static const AppColors dark = AppColors(
    bg: Color(0xFF0F1115),
    surface: Color(0xFF1A1D23),
    textPrimary: Color(0xFFE6E8EB),
    textSecondary: Color(0xFF9AA0A6),
    border: Color(0xFF2A2E36),
    bubbleUser: Color(0xFF1F6FEB),
    bubbleAssistant: Color(0xFF1A1D23),
    thinking: Color(0xFF2C2418),
    thinkingAccent: Color(0xFFE0B96A),
    thinkingBorder: Color(0xFF4A3A1E),
    thinkingText: Color(0xFFE0B96A),
    toolCallBg: Color(0xFF161A20),
    toolCallBorder: Color(0xFF2A2E36),
    codeBlockBg: Color(0xFF161A20),
    codeBlockBorder: Color(0xFF2A2E36),
    errorBg: Color(0xFF2A1818),
    errorBorder: Color(0xFF5A2828),
    errorText: Color(0xFFFF8A8A),
  );

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? textPrimary,
    Color? textSecondary,
    Color? border,
    Color? bubbleUser,
    Color? bubbleAssistant,
    Color? thinking,
    Color? thinkingAccent,
    Color? thinkingBorder,
    Color? thinkingText,
    Color? toolCallBg,
    Color? toolCallBorder,
    Color? codeBlockBg,
    Color? codeBlockBorder,
    Color? errorBg,
    Color? errorBorder,
    Color? errorText,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      border: border ?? this.border,
      bubbleUser: bubbleUser ?? this.bubbleUser,
      bubbleAssistant: bubbleAssistant ?? this.bubbleAssistant,
      thinking: thinking ?? this.thinking,
      thinkingAccent: thinkingAccent ?? this.thinkingAccent,
      thinkingBorder: thinkingBorder ?? this.thinkingBorder,
      thinkingText: thinkingText ?? this.thinkingText,
      toolCallBg: toolCallBg ?? this.toolCallBg,
      toolCallBorder: toolCallBorder ?? this.toolCallBorder,
      codeBlockBg: codeBlockBg ?? this.codeBlockBg,
      codeBlockBorder: codeBlockBorder ?? this.codeBlockBorder,
      errorBg: errorBg ?? this.errorBg,
      errorBorder: errorBorder ?? this.errorBorder,
      errorText: errorText ?? this.errorText,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      border: Color.lerp(border, other.border, t)!,
      bubbleUser: Color.lerp(bubbleUser, other.bubbleUser, t)!,
      bubbleAssistant: Color.lerp(bubbleAssistant, other.bubbleAssistant, t)!,
      thinking: Color.lerp(thinking, other.thinking, t)!,
      thinkingAccent: Color.lerp(thinkingAccent, other.thinkingAccent, t)!,
      thinkingBorder: Color.lerp(thinkingBorder, other.thinkingBorder, t)!,
      thinkingText: Color.lerp(thinkingText, other.thinkingText, t)!,
      toolCallBg: Color.lerp(toolCallBg, other.toolCallBg, t)!,
      toolCallBorder: Color.lerp(toolCallBorder, other.toolCallBorder, t)!,
      codeBlockBg: Color.lerp(codeBlockBg, other.codeBlockBg, t)!,
      codeBlockBorder: Color.lerp(codeBlockBorder, other.codeBlockBorder, t)!,
      errorBg: Color.lerp(errorBg, other.errorBg, t)!,
      errorBorder: Color.lerp(errorBorder, other.errorBorder, t)!,
      errorText: Color.lerp(errorText, other.errorText, t)!,
    );
  }
}

extension AppColorsContext on BuildContext {
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.light;
  Color get bg => appColors.bg;
  Color get surface => appColors.surface;
  Color get textPrimary => appColors.textPrimary;
  Color get textSecondary => appColors.textSecondary;
  Color get appBorder => appColors.border;
  Color get bubbleUser => appColors.bubbleUser;
  Color get bubbleAssistant => appColors.bubbleAssistant;
  Color get thinkingBg => appColors.thinking;
  Color get thinkingAccent => appColors.thinkingAccent;
  Color get thinkingBorder => appColors.thinkingBorder;
  Color get thinkingText => appColors.thinkingText;
  Color get toolCallBg => appColors.toolCallBg;
  Color get codeBlockBg => appColors.codeBlockBg;
  Color get codeBlockBorder => appColors.codeBlockBorder;
  Color get errorBg => appColors.errorBg;
  Color get errorBorder => appColors.errorBorder;
  Color get errorText => appColors.errorText;
}
