import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import '../models/builtin_model.dart';

/// Catalog of the built-in chat-template presets that ship with the
/// app, plus a small helper that maps a [BuiltinModel] to its
/// "best fit" preset key.
///
/// The presets live as `.jinja` files under `assets/jinja/` so the
/// user can drop in a corrected upstream template by replacing the
/// file in the source tree — no Dart code change needed. The
/// settings UI exposes three chips (qwen / gemma / minicpm5); each
/// chip auto-fills the textarea with the corresponding asset.
///
/// Wire format: presets are resolved by **stable string keys** in
/// the UI (`qwen`, `gemma`, `minicpm5`). The keys are also embedded
/// in the asset filename (`chat_template_<key>.jinja`) so adding a
/// new preset is a two-step process:
///   1. drop `assets/jinja/chat_template_<key>.jinja`
///   2. add the key + asset path to [_presets] below
class ChatTemplatePresets {
  ChatTemplatePresets._();

  /// Stable id → asset path. The id is what the settings UI shows
  /// on the chip; the asset path is what `rootBundle.loadString`
  /// reads. Keep this list ordered to match the chip rendering
  /// order (left to right) in the local-provider form.
  static const Map<String, String> _presets = {
    'qwen': 'assets/jinja/chat_template_qwen.jinja',
    'gemma': 'assets/jinja/chat_template_gemma.jinja',
    'minicpm5': 'assets/jinja/chat_template_minicpm5.jinja',
  };

  /// Display labels for the chips. English-only on purpose — these
  /// are model-family names (qwen / gemma / minicpm5), not
  /// localized UI copy, so we keep them verbatim regardless of the
  /// user's locale.
  static const Map<String, String> _labels = {
    'qwen': 'qwen',
    'gemma': 'gemma',
    'minicpm5': 'minicpm5',
  };

  /// Preset keys in the order they should appear as chips in the
  /// form. Computed from [_presets]'s insertion order so a code
  /// change that re-orders the map (via `LinkedHashMap` semantics)
  /// automatically re-orders the UI.
  static List<String> get keys => _presets.keys.toList(growable: false);

  /// Display label for a preset key. Falls back to the key itself
  /// when an unknown id is passed (defensive — shouldn't happen
  /// because the chips are rendered from [keys], but a future
  /// caller might pass a stale id from persisted state).
  static String labelOf(String key) => _labels[key] ?? key;

  /// Asset path for a preset key, or `null` if the id is unknown.
  /// Used by the form's "load on tap" handler.
  static String? assetPathFor(String key) => _presets[key];

  /// Returns `true` if [key] is a recognised preset id.
  static bool isPresetKey(String key) => _presets.containsKey(key);

  /// Asynchronously loads the Jinja source for [key] from the app
  /// asset bundle. Returns `null` if the key is unknown or the
  /// asset read fails (logged once at debug level). Callers
  /// should treat a `null` result as a non-fatal user-facing
  /// error (e.g. "模板加载失败" toast) — never a chat-blocking
  /// exception.
  static Future<String?> load(String key) async {
    final path = _presets[key];
    if (path == null) return null;
    try {
      return await rootBundle.loadString(path);
    } catch (e, st) {
      debugPrint('ChatTemplatePresets.load failed for $key ($path): $e\n$st');
      return null;
    }
  }

  /// Best-effort match between a [BuiltinModel.id] and a preset
  /// key. The match is intentionally substring-based so a new
  /// built-in card named `qwen3.5-...` or `gemma-4-...` auto-fills
  /// the right template without us having to maintain an explicit
  /// table. Returns `null` when no match is found (the form then
  /// leaves the template field empty and the user picks a chip by
  /// hand).
  static String? presetKeyForBuiltin(String builtinModelId) {
    final lower = builtinModelId.toLowerCase();
    if (lower.contains('qwen')) return 'qwen';
    if (lower.contains('gemma')) return 'gemma';
    if (lower.contains('minicpm') || lower.contains('mini-cpm')) {
      return 'minicpm5';
    }
    return null;
  }

  /// Convenience wrapper for [presetKeyForBuiltin] that handles
  /// the `null` builtin id (user-added local provider — no
  /// built-in card to seed from). Always returns `null` for a
  /// user-added row.
  static String? presetKeyForBuiltinModel(BuiltinModel? model) {
    if (model == null) return null;
    return presetKeyForBuiltin(model.id);
  }
}
