import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// Base class for all built-in tools.
///
/// Each subclass defines its own identity (id, name, description),
/// platform support rules, and the OpenAI-style function schema
/// used to tell the model about this tool.
abstract class ToolBase {
  /// Unique snake_case identifier (e.g. `'fetch_web'`).
  String get id;

  /// Human-readable name in simplified Chinese (for UI display).
  String get name;

  /// Description in simplified Chinese — shown to the model as the
  /// tool's function description, and also used in the settings UI.
  String get description;

  /// Whether this tool can actually run on the current platform.
  bool get isSupportedOnCurrentPlatform;

  /// Returns the OpenAI-style function-calling schema entry for
  /// this tool, or `null` if the tool is not supported on the
  /// current platform.
  Map<String, dynamic> buildSchema();
}

/// Convenience helpers for common platform checks.
bool isDesktop() =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

bool isMobile() => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

bool notWeb() => !kIsWeb;
