import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, protected;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;

import '../tool_service.dart';

/// Base class for all built-in tools.
///
/// Each subclass defines its own identity (id, name, description),
/// platform support rules, the OpenAI-style function schema, and
/// the execution logic in [execute].
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

  /// Whether this tool should be enabled out of the box on a fresh
  /// install. Most tools default to `true` so the user gets the
  /// full toolset without having to flip switches. Tools that
  /// require a one-time setup step (e.g. `reminders` on Android
  /// needs the user to pick a "todo" calendar) override this to
  /// `false` so the picker / setup flow is the user's first
  /// interaction with the tool, not a silent failure.
  bool get isEnabledByDefault => true;

  /// Returns the OpenAI-style function-calling schema entry for
  /// this tool, or `null` if the tool is not supported on the
  /// current platform.
  Map<String, dynamic> buildSchema();

  /// Execute this tool with the given [args] (from the model's
  /// function-call arguments) and [services] (the shared service
  /// container). Returns a JSON string that the model can parse.
  Future<String> execute(Map<String, dynamic> args, ToolService services);

  /// Wraps platform-specific exceptions ([UnsupportedError],
  /// [MissingPluginException], [PlatformException]) into a
  /// [ToolException] with a friendly message for the model.
  @protected
  Future<String> wrapPlatformExceptions(
    Future<String> Function() fn,
    String toolName,
  ) async {
    try {
      return await fn();
    } on ToolException {
      rethrow;
    } on UnsupportedError catch (e) {
      throw ToolException('${e.message} ($toolName)');
    } on MissingPluginException {
      throw ToolException(
        '$toolName is not available: native bridge not registered',
      );
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw ToolException(
          '$toolName permission denied; please grant it in system settings',
        );
      }
      throw ToolException('$toolName error: ${e.code}: ${e.message}');
    }
  }
}

/// Convenience helpers for common platform checks.
bool isDesktop() =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

bool isMobile() => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

bool notWeb() => !kIsWeb;
