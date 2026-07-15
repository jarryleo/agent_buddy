/// Catalog entry for a model that ships with the app and is offered
/// to the user as a one-tap "Download" affordance in the local model
/// settings. Lives separately from [LocalProvider] — the latter is
/// a user-configured row in the local providers list and is what the
/// local LLM engine actually loads. A built-in model only becomes a
/// [LocalProvider] once the user has downloaded its weights and
/// saved it from the built-in download page.
///
/// Files land in `getApplicationDocumentsDirectory()/local_models/<id>/`
/// so they survive across app restarts (the OS may still wipe the
/// directory on uninstall — that's the standard contract).
class BuiltinModel {
  const BuiltinModel({
    required this.id,
    required this.displayName,
    required this.description,
    required this.modelUrl,
    required this.modelFilename,
    this.mmprojUrl,
    this.mmprojFilename,
    this.approxSizeBytes = 0,
  });

  /// Stable id used in on-disk directory names and as the lookup
  /// key from the settings page. Never changes across app versions
  /// for a given model.
  final String id;

  /// Human-friendly name shown in the UI. Localized copy is rendered
  /// separately via [displayNameKey] when one is registered; for now
  /// the value is rendered as-is and matches the upstream model card.
  final String displayName;

  /// One-sentence description. Rendered as muted helper text under
  /// the model name in the built-in download page.
  final String description;

  /// URL of the main model weights file (`.gguf`).
  final String modelUrl;

  /// Filename to save the model weights as inside the destination
  /// directory. Sourced from the URL's last path segment by default.
  final String modelFilename;

  /// Optional URL of the multimodal projector (`.gguf`) — only
  /// present for vision-capable models.
  final String? mmprojUrl;

  /// Filename to save the mmproj as inside the destination directory.
  final String? mmprojFilename;

  /// Approximate on-disk size of the model weights in bytes.
  /// `0` when unknown. The value is shown to the user as "约 X GB"
  /// before they start the download.
  final int approxSizeBytes;

  bool get hasMmproj => mmprojUrl != null && mmprojUrl!.isNotEmpty;
}

/// Registry of every built-in model the app knows about. New entries
/// only need to be appended to [all]; the lookup map is built once
/// at first access. Models are shown in declaration order.
class BuiltinModels {
  BuiltinModels._();

  /// Built-in models offered to the user as one-tap downloads.
  /// Additional entries can be appended below — the settings UI
  /// iterates [all] in declaration order.
  static const List<BuiltinModel> all = [
    BuiltinModel(
      id: 'gemma-4-e2b-it-qat-q4_0',
      displayName: 'gemma-4-E2B-it-qat-q4_0',
      description: 'Google Gemma 4 2B Q4_0 量化版,带 mmproj 支持多模态(图片输入)。',
      modelUrl:
          'https://www.modelscope.cn/models/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/master/gemma-4-E2B_q4_0-it.gguf',
      modelFilename: 'gemma-4-E2B_q4_0-it.gguf',
      mmprojUrl:
          'https://www.modelscope.cn/models/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/master/gemma-4-E2B-it-mmproj.gguf',
      mmprojFilename: 'gemma-4-E2B-it-mmproj.gguf',
      approxSizeBytes: 4200000000,
    ),
    BuiltinModel(
      id: 'qwen3.5-0.8b-q4_k_m',
      displayName: 'Qwen3.5-0.8B-Q4_K_M',
      description: 'Qwen3.5 0.8B Q4_K_M 量化版,体量小、加载快,带 mmproj 支持多模态(图片输入)。',
      modelUrl:
          'https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/Qwen3.5-0.8B-Q4_K_M.gguf',
      modelFilename: 'Qwen3.5-0.8B-Q4_K_M.gguf',
      mmprojUrl:
          'https://www.modelscope.cn/models/unsloth/Qwen3.5-0.8B-GGUF/resolve/master/mmproj-BF16.gguf',
      mmprojFilename: 'mmproj-BF16.gguf',
      approxSizeBytes: 800000000,
    ),
  ];

  static final Map<String, BuiltinModel> _byId = {for (final m in all) m.id: m};

  /// O(1) id lookup. Returns `null` when the id isn't a known
  /// built-in (e.g. an old persisted entry referencing a model that
  /// has since been removed from the catalog).
  static BuiltinModel? byId(String id) => _byId[id];
}
