import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/builtin_model.dart';
import '../models/local_provider.dart';
import '../providers/settings_provider.dart';
import '../services/builtin_model_download_service.dart';
import '../services/gguf_metadata.dart';
import '../services/memory_estimator.dart' show formatBytes;
import '../theme/app_theme.dart';
import 'widgets/local_provider_form_fields.dart';

/// Page for downloading a built-in model and saving it as a
/// [LocalProvider], or for editing the parameters of an existing
/// built-in-backed [LocalProvider].
///
/// Two modes:
///   * **New** (no `existing`) — user has to download the model +
///     mmproj, configure parameters, then Save to create the
///     linked [LocalProvider].
///   * **Edit** (`existing != null`) — the linked [LocalProvider]
///     already exists. The file paths are pinned to the existing
///     values, the download section is collapsed to a "re-download
///     if you want" affordance, and Save updates the existing row
///     in place (no new card appears in the providers list).
///
/// The download is **stateful**: it lives on a long-lived
/// [BuiltinModelDownloadService] (provided via DI). The page
/// subscribes to it via `context.watch` so progress / errors /
/// completion flow through the service even when the page is
/// not on top. Closing the page does NOT cancel an in-flight
/// download — the user can navigate away and come back to find
/// it still running.
class BuiltinModelDownloadPage extends StatefulWidget {
  const BuiltinModelDownloadPage({
    super.key,
    required this.settings,
    required this.model,
    this.existing,
  });

  final SettingsProvider settings;
  final BuiltinModel model;

  /// When non-null, the page is editing this existing built-in-
  /// backed [LocalProvider] instead of creating a new one.
  final LocalProvider? existing;

  @override
  State<BuiltinModelDownloadPage> createState() =>
      _BuiltinModelDownloadPageState();
}

class _BuiltinModelDownloadPageState extends State<BuiltinModelDownloadPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _name;
  late int _contextSize;
  late double _temperature;
  late int _gpuLayers;
  late int _maxTokens;
  late String _cacheTypeK;
  late String _cacheTypeV;
  late int _batchSize;

  /// Resolved absolute paths to the files we should pass to the
  /// [LocalProvider]. In "edit" mode these start as the existing
  /// row's paths; in "new" mode they're set when the download
  /// completes successfully (or resumed from the on-disk partial
  /// if the service had one in flight).
  String? _modelPath;
  String? _mmprojPath;

  int? _modelFileSize;
  ModelArchitecture? _modelArch;
  bool _archLoading = false;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(
      text: existing?.name ?? widget.model.displayName,
    );
    _contextSize = existing?.contextSize ?? 4096;
    _temperature = existing?.temperature ?? 0.7;
    _gpuLayers = existing?.gpuLayers ?? 0;
    _maxTokens = existing?.maxTokens ?? 1024;
    _cacheTypeK = existing?.cacheTypeK ?? _defaultKvCacheTypeK();
    _cacheTypeV = existing?.cacheTypeV ?? _defaultKvCacheTypeV();
    _batchSize = existing?.batchSize ?? LocalProvider.kDefaultBatchSize;

    if (existing != null) {
      // Edit mode: file paths are already known (pinned to the
      // existing row). Read the GGUF header so the memory
      // estimate card is populated.
      _modelPath = existing.modelPath;
      _mmprojPath = existing.mmprojPath;
      _refreshModelMetadata(existing.modelPath);
    } else {
      // New mode: pre-resolve the destination paths so the
      // download card has somewhere to point to.
      _bootstrapPaths();
    }
  }

  /// On mobile the RAM and VRAM budgets are usually much smaller
  /// than on a desktop, so we default to q8_0 (K) + q4_0 (V) to
  /// give the model a fighting chance at larger context windows.
  /// Desktop / web keep the llama.cpp default of f16 for max
  /// quality.
  static bool get _isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  static String _defaultKvCacheTypeK() => _isMobile ? 'q8_0' : 'f16';
  static String _defaultKvCacheTypeV() => _isMobile ? 'q4_0' : 'f16';

  BuiltinModelDownloadService get _service =>
      context.read<BuiltinModelDownloadService>();

  Future<void> _bootstrapPaths() async {
    final service = _service;
    try {
      final paths = await service.resolvePaths(widget.model);
      if (!mounted) return;
      setState(() {
        _modelPath = paths.modelPath;
        _mmprojPath = paths.mmprojPath;
      });
    } catch (_) {
      // path_provider blew up (e.g. web). The download button
      // will surface the error when pressed.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// User actions — wired to the service.

  void _startDownload() {
    _service.startDownload(widget.model);
  }

  void _cancelDownload() {
    _service.cancel(widget.model.id);
  }

  /// Re-download from scratch: drop the on-disk file (full or
  /// partial) and start a fresh transfer. Used by the
  /// "重新下载" affordance.
  Future<void> _restartDownload() async {
    await _service.deleteDownloadedFiles(widget.model);
    if (!mounted) return;
    // The on-disk files are gone, so the page's local path
    // cache is now stale — drop it so the UI flips back to
    // the "no file on disk" state until the next download
    // populates it again.
    setState(() {
      _modelPath = null;
      _mmprojPath = null;
      _modelFileSize = null;
      _modelArch = null;
    });
    _service.startDownload(widget.model);
  }

  /// Per-file delete handler used by the inline trash icons on
  /// [_DownloadFileRow] (new mode) and [_PathRow] (edit mode).
  ///
  /// The [file] argument is the [BuiltinFileDownload] object
  /// the row is currently rendering (or a synthesised one for
  /// the edit-mode `_PathRow`). The service identifies which
  /// slot to reset by comparing the file's URL against the
  /// model's [BuiltinModel.modelUrl] / [BuiltinModel.mmprojUrl].
  ///
  /// Pops a confirmation dialog before doing anything
  /// destructive — deleting a fully downloaded model is a
  /// user-visible loss, so we want a one-tap undo.
  Future<void> _onDeleteFile(BuiltinFileDownload file) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(l10n.builtinModelDeleteFileConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final isModel = file.url == widget.model.modelUrl;
    await _service.deleteDownloadedFile(widget.model, file);
    if (!mounted) return;
    setState(() {
      if (isModel) {
        _modelPath = null;
        _modelFileSize = null;
        _modelArch = null;
      } else {
        _mmprojPath = null;
      }
    });
  }

  Future<void> _refreshModelMetadata(String path) async {
    if (kIsWeb) {
      setState(() {
        _archLoading = false;
        _modelFileSize = null;
        _modelArch = null;
      });
      return;
    }
    int? size;
    try {
      final f = File(path);
      if (await f.exists()) {
        size = await f.length();
      }
    } catch (_) {
      size = null;
    }
    final arch = await const GgufMetadataReader().read(path);
    if (!mounted) return;
    setState(() {
      _modelFileSize = size;
      _modelArch = arch;
      _archLoading = false;
    });
  }

  /// True when the file paths the page knows about actually exist
  /// on disk. Save is blocked until this is true (otherwise we'd
  /// create a [LocalProvider] pointing at a non-existent file).
  bool get _hasFilesOnDisk {
    final mp = _modelPath;
    if (mp == null) return false;
    if (kIsWeb) return true;
    if (!File(mp).existsSync()) return false;
    final mmproj = _mmprojPath;
    if (mmproj != null && mmproj.isNotEmpty && !File(mmproj).existsSync()) {
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final modelPath = _modelPath;
    if (modelPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).builtinModelDownloadRequired,
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!kIsWeb && !File(modelPath).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).localProviderFileMissing(modelPath),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final name = _name.text.trim().isEmpty
        ? widget.model.displayName
        : _name.text.trim();
    final mmprojPath = (_mmprojPath == null || _mmprojPath!.isEmpty)
        ? null
        : _mmprojPath;
    final existing = widget.existing;
    if (existing == null) {
      // New mode: create the row with builtinModelId so the
      // providers list filters it out and the built-in card
      // becomes the entry point for editing.
      await widget.settings.addLocalProvider(
        name: name,
        modelPath: modelPath,
        mmprojPath: mmprojPath,
        contextSize: _contextSize,
        temperature: _temperature,
        gpuLayers: _gpuLayers,
        maxTokens: _maxTokens,
        cacheTypeK: _cacheTypeK,
        cacheTypeV: _cacheTypeV,
        batchSize: _batchSize,
        builtinModelId: widget.model.id,
      );
    } else {
      // Edit mode: keep the same id, the same builtinModelId, and
      // preserve the user's existing enabled / createdAt by
      // mutating only the editable fields.
      await widget.settings.updateLocalProvider(
        existing.copyWith(
          name: name,
          modelPath: modelPath,
          mmprojPath: mmprojPath,
          contextSize: _contextSize,
          temperature: _temperature,
          gpuLayers: _gpuLayers,
          maxTokens: _maxTokens,
          cacheTypeK: _cacheTypeK,
          cacheTypeV: _cacheTypeV,
          batchSize: _batchSize,
        ),
      );
    }
    if (!mounted) return;
    // Drop the in-memory download state — the file is on disk
    // and a LocalProvider points to it; the snapshot in the
    // service would just be stale noise. The next time the
    // user re-opens the page in "edit" mode, the file existence
    // is the source of truth.
    _service.clearState(widget.model.id);
    setState(() => _saving = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Watch the service so progress updates rebuild the page.
    // This is the bridge between the long-lived download
    // (which keeps running even when the page is disposed) and
    // the live UI.
    return Consumer<BuiltinModelDownloadService>(
      builder: (context, service, _) {
        final state = service.stateFor(widget.model.id);
        // Pull the latest local paths off the service's state
        // so a download that completes while the page is
        // backgrounded immediately reflects in our form.
        if (state != null) {
          if (state.modelPath != null) _modelPath = state.modelPath;
          if (state.mmprojPath != null) _mmprojPath = state.mmprojPath;
          if (state.modelFile.status == BuiltinFileStatus.completed &&
              !_archLoading) {
            // Re-read GGUF metadata from the freshly downloaded
            // file so the memory estimate card reflects the
            // actual architecture. The path may have been set
            // before initState ran (e.g. if the user backgrounded
            // a download and came back).
            final mp = state.modelPath;
            if (mp != null && _modelFileSize == null) {
              _refreshModelMetadata(mp);
            }
          }
        }
        final canSave =
            _hasFilesOnDisk &&
            (state == null || !state.isActive) &&
            (state == null ||
                state.overall != BuiltinModelDownloadPhase.failed);
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _isEdit ? l10n.builtinModelEditTitle : widget.model.displayName,
            ),
          ),
          body: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _BuiltinHeader(
                  model: widget.model,
                  isEdit: _isEdit,
                  downloaded: _hasFilesOnDisk,
                ),
                const SizedBox(height: 14),
                LocalProviderFormLabel(text: l10n.localProviderName),
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(
                    hintText: l10n.localProviderNameHint,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? l10n.localProviderNameRequired
                      : null,
                ),
                const SizedBox(height: 14),
                if (!_isEdit)
                  _DownloadSection(
                    model: widget.model,
                    service: service,
                    onStart: _startDownload,
                    onCancel: _cancelDownload,
                    onRestart: _restartDownload,
                    onContinue: _startDownload,
                    onDeleteFile: _onDeleteFile,
                  )
                else
                  _InstalledFilesRow(
                    model: widget.model,
                    modelPath: _modelPath,
                    mmprojPath: _mmprojPath,
                    service: service,
                    onStart: _startDownload,
                    onCancel: _cancelDownload,
                    onRestart: _restartDownload,
                    onDeleteFile: _onDeleteFile,
                  ),
                const SizedBox(height: 20),
                MemoryEstimateCard(
                  modelFileSize: _modelFileSize,
                  arch: _modelArch,
                  loading: _archLoading,
                  contextSize: _contextSize,
                  batchSize: _batchSize,
                  cacheTypeK: _cacheTypeK,
                  cacheTypeV: _cacheTypeV,
                  modelLabel: l10n.localProviderMemModel,
                  kvLabel: l10n.localProviderMemKv,
                  computeLabel: l10n.localProviderMemCompute,
                  totalLabel: l10n.localProviderMemTotal,
                  missingLabel: l10n.localProviderMemMissing,
                  loadingLabel: l10n.localProviderMemLoading,
                ),
                const SizedBox(height: 16),
                LocalProviderFormLabel(text: l10n.localProviderParams),
                const SizedBox(height: 4),
                ContextSizeSlider(
                  value: _contextSize,
                  presets: LocalProviderPresets.contextSize,
                  onChanged: (v) => setState(() => _contextSize = v),
                  label: l10n.localProviderContextSize,
                ),
                const SizedBox(height: 16),
                SliderField(
                  value: _temperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  onChanged: (v) => setState(() => _temperature = v),
                  label: l10n.localProviderTemperature,
                  display: _temperature.toStringAsFixed(2),
                ),
                const SizedBox(height: 16),
                GpuLayersField(
                  value: _gpuLayers,
                  onChanged: (v) => setState(() => _gpuLayers = v),
                  label: l10n.localProviderGpuLayers,
                  hint: l10n.localProviderGpuLayersHint,
                ),
                const SizedBox(height: 16),
                MaxTokensSlider(
                  value: _maxTokens,
                  presets: LocalProviderPresets.maxTokens,
                  onChanged: (v) => setState(() => _maxTokens = v),
                  label: l10n.localProviderMaxTokens,
                ),
                const SizedBox(height: 16),
                KvCacheTypeField(
                  label: l10n.localProviderKvCacheK,
                  hint: l10n.localProviderKvCacheHint,
                  value: _cacheTypeK,
                  onChanged: (v) => setState(() => _cacheTypeK = v),
                ),
                const SizedBox(height: 12),
                KvCacheTypeField(
                  label: l10n.localProviderKvCacheV,
                  hint: null,
                  value: _cacheTypeV,
                  onChanged: (v) => setState(() => _cacheTypeV = v),
                ),
                const SizedBox(height: 16),
                BatchSizeSlider(
                  value: _batchSize,
                  presets: LocalProviderPresets.batchSize,
                  onChanged: (v) => setState(() => _batchSize = v),
                  label: l10n.localProviderBatchSize,
                  hint: l10n.localProviderBatchSizeHint,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    onPressed: (_saving || !canSave) ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(l10n.commonSave),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Top-of-page card showing the model name + one-line description
/// + a "约 X GB" size hint + a status pill. Always visible so
/// the user can read what they're about to install or edit.
class _BuiltinHeader extends StatelessWidget {
  const _BuiltinHeader({
    required this.model,
    required this.isEdit,
    required this.downloaded,
  });

  final BuiltinModel model;
  final bool isEdit;
  final bool downloaded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final approx = model.approxSizeBytes > 0
        ? l10n.builtinModelApproxSize(
            formatBytes(model.approxSizeBytes, decimals: 1),
          )
        : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isEdit ? Icons.tune : Icons.cloud_download_outlined,
                  size: 18,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  model.displayName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (downloaded)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F883D).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    l10n.builtinModelDownloaded,
                    style: const TextStyle(
                      color: Color(0xFF1F883D),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            model.description,
            style: TextStyle(fontSize: 12, color: context.textSecondary),
          ),
          if (approx != null) ...[
            const SizedBox(height: 6),
            Text(
              approx,
              style: TextStyle(fontSize: 11, color: context.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// New-mode download section. Drives the lifecycle of a single
/// in-flight download via the shared [BuiltinModelDownloadService]:
///
///   * **no file on disk, no active download** → "下载" (fresh).
///   * **downloading** → "取消" + live progress.
///   * **completed (file on disk)** → "重新下载" (secondary).
///   * **cancelled / failed with partial on disk** → "继续" (resume)
///     + "重新下载" (start over).
///   * **cancelled / failed with no partial** → "重试" (re-attempt).
class _DownloadSection extends StatelessWidget {
  const _DownloadSection({
    required this.model,
    required this.service,
    required this.onStart,
    required this.onCancel,
    required this.onRestart,
    required this.onContinue,
    required this.onDeleteFile,
  });

  final BuiltinModel model;
  final BuiltinModelDownloadService service;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onRestart;
  final VoidCallback onContinue;
  final Future<void> Function(BuiltinFileDownload file) onDeleteFile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = service.stateFor(model.id);
    final isActive = service.isActive(model.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LocalProviderFormLabel(text: l10n.builtinModelFiles),
        _DownloadFileRow(
          title: l10n.builtinModelWeightsFile,
          file: state?.modelFile,
          isCurrent:
              state?.overall == BuiltinModelDownloadPhase.downloadingModel,
          isQueued:
              state?.overall == BuiltinModelDownloadPhase.downloadingMmproj,
          onDelete: (f) => onDeleteFile(f),
        ),
        if (model.hasMmproj) ...[
          const SizedBox(height: 8),
          _DownloadFileRow(
            title: l10n.builtinModelMmprojFile,
            file: state?.mmprojFile,
            isCurrent:
                state?.overall == BuiltinModelDownloadPhase.downloadingMmproj,
            isQueued:
                state?.overall == BuiltinModelDownloadPhase.downloadingModel,
            onDelete: (f) => onDeleteFile(f),
          ),
        ],
        if (state?.overall == BuiltinModelDownloadPhase.failed) ...[
          const SizedBox(height: 8),
          Text(
            l10n.builtinModelDownloadFailed(
              state!.modelFile.error ?? state.mmprojFile?.error ?? '',
            ),
            style: const TextStyle(fontSize: 11, color: Color(0xFFD1242F)),
          ),
        ],
        const SizedBox(height: 12),
        _ActionRow(
          state: state,
          isActive: isActive,
          onStart: onStart,
          onCancel: onCancel,
          onRestart: onRestart,
          onContinue: onContinue,
        ),
      ],
    );
  }
}

/// Renders the action buttons for the download card. The exact
/// set of buttons depends on the current state:
///
///   * active  → "取消下载" (full width)
///   * terminal + can resume  → "继续" + "重新下载"
///   * terminal + no partial + completed → "重新下载" (secondary)
///   * terminal + no partial + failed → "重试" + "重新下载"
///   * nothing in flight, no file → "下载" (full width)
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.state,
    required this.isActive,
    required this.onStart,
    required this.onCancel,
    required this.onRestart,
    required this.onContinue,
  });

  final BuiltinModelDownloadState? state;
  final bool isActive;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onRestart;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (isActive) {
      // The user can stop the background download at any time
      // (the download survives closing the page).
      return _PrimaryButton(
        icon: Icons.close,
        label: l10n.builtinModelCancelDownload,
        onPressed: onCancel,
        outlined: true,
      );
    }
    final overall = state?.overall;
    if (overall == BuiltinModelDownloadPhase.cancelled ||
        overall == BuiltinModelDownloadPhase.failed) {
      // We have a partial on disk — offer to resume from the
      // breakpoint, or start over.
      if (state?.canResume ?? false) {
        return Row(
          children: [
            Expanded(
              child: _PrimaryButton(
                icon: Icons.play_arrow,
                label: l10n.builtinModelResume,
                onPressed: onContinue,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PrimaryButton(
                icon: Icons.refresh,
                label: l10n.builtinModelRedownload,
                onPressed: onRestart,
                outlined: true,
              ),
            ),
          ],
        );
      }
      // No partial on disk — offer a retry + a from-scratch
      // restart.
      return _PrimaryButton(
        icon: Icons.refresh,
        label: l10n.builtinModelRetry,
        onPressed: onStart,
      );
    }
    if (overall == BuiltinModelDownloadPhase.completed) {
      // File is on disk; show a secondary "重新下载" affordance
      // (the user might want to refresh the model, e.g. after
      // the upstream was updated, or after the file went
      // missing).
      return _PrimaryButton(
        icon: Icons.refresh,
        label: l10n.builtinModelRedownload,
        onPressed: onRestart,
        outlined: true,
      );
    }
    // Nothing in flight, no file on disk — fresh download.
    return _PrimaryButton(
      icon: Icons.download_outlined,
      label: l10n.builtinModelDownload,
      onPressed: onStart,
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.outlined = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    // Horizontal padding so the icon + label don't sit flush
    // against the button edge; minimumSize keeps a consistent
    // tap target even for short labels.
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    const minimumSize = Size(0, 44);
    if (outlined) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          shape: shape,
          padding: padding,
          minimumSize: minimumSize,
          side: BorderSide(color: context.appBorder, width: 0.8),
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        shape: shape,
        elevation: 0,
        padding: padding,
        minimumSize: minimumSize,
      ),
    );
  }
}

/// Edit-mode card. Replaces the download section: the linked
/// [LocalProvider] is already pointing at the on-disk file, so
/// the primary action is "Save" and "重新下载" is a secondary
/// affordance. Live progress is shown in-line when the user
/// kicks off a re-download.
class _InstalledFilesRow extends StatelessWidget {
  const _InstalledFilesRow({
    required this.model,
    required this.modelPath,
    required this.mmprojPath,
    required this.service,
    required this.onStart,
    required this.onCancel,
    required this.onRestart,
    required this.onDeleteFile,
  });

  final BuiltinModel model;
  final String? modelPath;
  final String? mmprojPath;
  final BuiltinModelDownloadService service;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onRestart;
  final Future<void> Function(BuiltinFileDownload file) onDeleteFile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = service.stateFor(model.id);
    final isActive = service.isActive(model.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LocalProviderFormLabel(text: l10n.builtinModelFiles),
        _PathRow(
          label: l10n.builtinModelWeightsFile,
          path: modelPath,
          isModel: true,
          model: model,
          onDelete: onDeleteFile,
        ),
        if (model.hasMmproj) ...[
          const SizedBox(height: 8),
          _PathRow(
            label: l10n.builtinModelMmprojFile,
            path: mmprojPath,
            isModel: false,
            model: model,
            onDelete: onDeleteFile,
          ),
        ],
        if (state != null && (state.isActive || state.canResume)) ...[
          const SizedBox(height: 10),
          _LiveProgress(state: state, model: model, onDeleteFile: onDeleteFile),
        ],
        if (state?.overall == BuiltinModelDownloadPhase.failed) ...[
          const SizedBox(height: 8),
          Text(
            l10n.builtinModelDownloadFailed(
              state!.modelFile.error ?? state.mmprojFile?.error ?? '',
            ),
            style: const TextStyle(fontSize: 11, color: Color(0xFFD1242F)),
          ),
        ],
        const SizedBox(height: 12),
        _ActionRow(
          state: state,
          isActive: isActive,
          onStart: onStart,
          onCancel: onCancel,
          onRestart: onRestart,
          onContinue: onStart,
        ),
      ],
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.label,
    required this.path,
    required this.isModel,
    required this.model,
    required this.onDelete,
  });

  final String label;
  final String? path;

  /// True for the model-weights row, false for the mmproj row.
  /// Used to construct a [BuiltinFileDownload] for the delete
  /// callback (the service keys off the URL).
  final bool isModel;

  /// The model the row belongs to. Needed to look up the right
  /// URL/filename when synthesizing the [BuiltinFileDownload]
  /// for the delete callback.
  final BuiltinModel model;

  final Future<void> Function(BuiltinFileDownload file) onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final hasFile = path != null && path!.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (hasFile)
                _DeleteFileIconButton(
                  tooltip: l10n.builtinModelDeleteFileTooltip,
                  onPressed: () {
                    final file = isModel
                        ? BuiltinFileDownload(
                            url: model.modelUrl,
                            filename: model.modelFilename,
                            localPath: path,
                            status: BuiltinFileStatus.completed,
                          )
                        : BuiltinFileDownload(
                            url: model.mmprojUrl!,
                            filename: model.mmprojFilename!,
                            localPath: path,
                            status: BuiltinFileStatus.completed,
                          );
                    onDelete(file);
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            path ?? '—',
            style: TextStyle(fontSize: 11, color: context.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Live progress widget used by the edit-mode "re-download"
/// flow. Mirrors the new-mode card so the user gets a
/// consistent look no matter which entry point they used.
class _LiveProgress extends StatelessWidget {
  const _LiveProgress({
    required this.state,
    required this.model,
    required this.onDeleteFile,
  });

  final BuiltinModelDownloadState state;
  final BuiltinModel model;
  final Future<void> Function(BuiltinFileDownload file) onDeleteFile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DownloadFileRow(
          title: l10n.builtinModelWeightsFile,
          file: state.modelFile,
          isCurrent:
              state.overall == BuiltinModelDownloadPhase.downloadingModel,
          isQueued:
              state.overall == BuiltinModelDownloadPhase.downloadingMmproj,
          onDelete: (f) => onDeleteFile(f),
        ),
        if (model.hasMmproj) ...[
          const SizedBox(height: 8),
          _DownloadFileRow(
            title: l10n.builtinModelMmprojFile,
            file: state.mmprojFile,
            isCurrent:
                state.overall == BuiltinModelDownloadPhase.downloadingMmproj,
            isQueued:
                state.overall == BuiltinModelDownloadPhase.downloadingModel,
            onDelete: (f) => onDeleteFile(f),
          ),
        ],
      ],
    );
  }
}

/// One row inside the download section — filename + progress bar +
/// status. Three render modes:
///   * **idle / not yet started** — no progress bar, just a
///     "waiting" hint.
///   * **running** — determinate bar (when the server reported
///     Content-Length) or indeterminate bar (chunked transfer),
///     with a live byte counter.
///   * **terminal** — completed / failed / cancelled.
class _DownloadFileRow extends StatelessWidget {
  const _DownloadFileRow({
    required this.title,
    required this.file,
    required this.isCurrent,
    required this.isQueued,
    this.onDelete,
  });

  final String title;
  final BuiltinFileDownload? file;
  final bool isCurrent;
  final bool isQueued;

  /// Optional delete-file callback. When non-null AND the file
  /// is in a terminal state (failed / cancelled / completed),
  /// a small delete icon is shown next to the status label.
  /// The callback receives the [BuiltinFileDownload] object
  /// the row is rendering, so the parent can dispatch to the
  /// right slot (model weights vs. mmproj).
  final void Function(BuiltinFileDownload file)? onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final file = this.file;
    final fraction = file?.fraction;
    final status = file?.status ?? BuiltinFileStatus.pending;
    final statusLabel = _statusLabel(l10n, status);
    final statusColor = _statusColor(status);
    final filename = file?.filename ?? '';
    // Per-file delete is only meaningful once the file has
    // stopped streaming (terminal) — not while it's pending or
    // currently downloading.
    final canDelete =
        onDelete != null &&
        file != null &&
        (status == BuiltinFileStatus.failed ||
            status == BuiltinFileStatus.cancelled ||
            status == BuiltinFileStatus.completed);
    // Capture locally so the closure below can call it without
    // a null-check (Dart can't promote `this.onDelete` through
    // an instance field inside an inline arrow).
    final onDeleteFn = onDelete;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (canDelete)
                _DeleteFileIconButton(
                  tooltip: l10n.builtinModelDeleteFileTooltip,
                  onPressed: () => onDeleteFn!(file),
                ),
              const SizedBox(width: 4),
              Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            filename,
            style: TextStyle(fontSize: 11, color: context.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          _buildProgressRow(
            context: context,
            l10n: l10n,
            file: file,
            fraction: fraction,
            status: status,
            statusColor: statusColor,
            isCurrent: isCurrent,
            isQueued: isQueued,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressRow({
    required BuildContext context,
    required AppLocalizations l10n,
    required BuiltinFileDownload? file,
    required double? fraction,
    required BuiltinFileStatus status,
    required Color statusColor,
    required bool isCurrent,
    required bool isQueued,
  }) {
    // 1) Queued behind the model download — no bar, just a hint.
    if (isQueued) {
      return Text(
        l10n.builtinModelQueued,
        style: TextStyle(fontSize: 10, color: context.textSecondary),
      );
    }

    // 2) Idle / pre-download state. No bar — that was animating
    // on its own before, looking like a "ghost" download.
    if (file == null || (status == BuiltinFileStatus.pending && !isCurrent)) {
      return Text(
        l10n.builtinModelWaiting,
        style: TextStyle(fontSize: 10, color: context.textSecondary),
      );
    }

    // 3) Failed / cancelled — no bar; show the reason.
    if (status == BuiltinFileStatus.failed ||
        status == BuiltinFileStatus.cancelled) {
      if (file.error == null || file.error!.isEmpty) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          file.error!,
          style: const TextStyle(fontSize: 10, color: Color(0xFFD1242F)),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }

    // 4) Completed — full bar + final byte counter.
    if (status == BuiltinFileStatus.completed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: 1.0,
              minHeight: 4,
              backgroundColor: context.textSecondary.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),
          if (file.bytesTotal > 0) ...[
            const SizedBox(height: 4),
            Text(
              _progressLabel(l10n, file, fraction),
              style: TextStyle(fontSize: 10, color: context.textSecondary),
            ),
          ],
        ],
      );
    }

    // 5) Running.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fraction != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: context.textSecondary.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: const LinearProgressIndicator(minHeight: 4),
          ),
        const SizedBox(height: 4),
        Text(
          _progressLabel(l10n, file, fraction),
          style: TextStyle(fontSize: 10, color: context.textSecondary),
        ),
      ],
    );
  }

  String _progressLabel(
    AppLocalizations l10n,
    BuiltinFileDownload file,
    double? fraction,
  ) {
    if (file.bytesTotal > 0) {
      // 2-decimal percent, clamped so an over-shoot (resume
      // that briefly exceeds the previous total) doesn't print
      // ">100.00%".
      final fraction = file.bytesReceived / file.bytesTotal;
      final pct = (fraction * 100).clamp(0.0, 100.0).toStringAsFixed(2);
      return l10n.builtinModelProgressWithPercent(
        _bytesLabel(file.bytesReceived),
        _bytesLabel(file.bytesTotal),
        pct,
      );
    }
    return l10n.builtinModelProgressIndeterminate(
      _bytesLabel(file.bytesReceived),
    );
  }

  static String _statusLabel(AppLocalizations l10n, BuiltinFileStatus s) {
    switch (s) {
      case BuiltinFileStatus.pending:
        return l10n.builtinModelStatusPending;
      case BuiltinFileStatus.running:
        return l10n.builtinModelStatusRunning;
      case BuiltinFileStatus.completed:
        return l10n.builtinModelStatusCompleted;
      case BuiltinFileStatus.failed:
        return l10n.builtinModelStatusFailed;
      case BuiltinFileStatus.cancelled:
        return l10n.builtinModelStatusCancelled;
    }
  }

  static Color _statusColor(BuiltinFileStatus s) {
    switch (s) {
      case BuiltinFileStatus.pending:
      case BuiltinFileStatus.running:
        return AppTheme.primary;
      case BuiltinFileStatus.completed:
        return const Color(0xFF1F883D);
      case BuiltinFileStatus.failed:
      case BuiltinFileStatus.cancelled:
        return const Color(0xFFD1242F);
    }
  }

  static String _bytesLabel(int bytes) => formatBytes(bytes, decimals: 1);
}

/// Small red delete icon used on the per-file download cards.
/// Always paired with a confirmation dialog at the call site —
/// the button itself just fires [onPressed].
class _DeleteFileIconButton extends StatelessWidget {
  const _DeleteFileIconButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 18,
        // Tight tap target so the button sits nicely inline with
        // the status label without inflating the row's height.
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.delete_outline, size: 16, color: Color(0xFFD1242F)),
        ),
      ),
    );
  }
}
