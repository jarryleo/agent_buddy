import 'dart:io';

import 'package:flutter/foundation.dart'
    show kIsWeb, protected, visibleForTesting;
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

  /// Human-readable name in simplified Chinese. Persisted into
  /// the on-device `AgentTool` JSON so existing installs keep a
  /// usable label after a downgrade or refresh; the Settings →
  /// Tools tab prefers the [userNameKey] translation, falling
  /// back to this default when the locale has no entry.
  String get name;

  /// ARB key for the user-facing display name shown in the
  /// settings Tools tab. The default derives `toolName<PascalId>`
  /// from [id], e.g. `'memory'` → `'toolNameMemory'`,
  /// `'fetch_web'` → `'toolNameFetchWeb'`. Subclasses override
  /// only when they want a custom key name.
  String get userNameKey {
    final camel = id
        .split('_')
        .map((p) => p.isEmpty ? p : (p[0].toUpperCase() + p.substring(1)))
        .join();
    return 'toolName$camel';
  }

  /// Description in simplified Chinese — sent to the model as the
  /// tool's function description. **Not** the user-facing copy in
  /// the settings list (that's [userDescriptionKey] → l10n).
  String get description;

  /// ARB key for the user-facing one-liner shown in the settings
  /// Tools tab. The default derives `toolDesc<PascalId>` from
  /// [id], e.g. `'memory'` → `'toolDescMemory'`,
  /// `'fetch_web'` → `'toolDescFetchWeb'`. Subclasses override
  /// only when they want a custom key name.
  String get userDescriptionKey {
    final camel = id
        .split('_')
        .map((p) => p.isEmpty ? p : (p[0].toUpperCase() + p.substring(1)))
        .join();
    return 'toolDesc$camel';
  }

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

// -- Test overrides ------------------------------------------------------
//
// Tests that need to exercise the mobile branch of a tool (e.g.
// the `file` tool's pick / release / working:// path handling) can
// call [overridePlatform] in `setUp` to force a specific
// platform, and the override in `tearDown` (typically
// [resetPlatformOverrides]).
bool? _forcedIsDesktop;
bool? _forcedIsMobile;

@visibleForTesting
void overridePlatform({bool? isDesktopValue, bool? isMobileValue}) {
  _forcedIsDesktop = isDesktopValue;
  _forcedIsMobile = isMobileValue;
}

@visibleForTesting
void resetPlatformOverrides() {
  _forcedIsDesktop = null;
  _forcedIsMobile = null;
}

bool isDesktopForRuntime() {
  if (_forcedIsDesktop != null) return _forcedIsDesktop!;
  return isDesktop();
}

bool isMobileForRuntime() {
  if (_forcedIsMobile != null) return _forcedIsMobile!;
  return isMobile();
}
