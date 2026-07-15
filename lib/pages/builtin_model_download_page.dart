import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

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
class BuiltinModelDownloadPage extends StatefulWidget {
  const BuiltinModelDownloadPage({
    super.key,
    required this.settings,
    required this.model,
    this.existing,
    BuiltinModelDownloadService? downloadService,
  }) : _downloadService = downloadService;

  final SettingsProvider settings;
  final BuiltinModel model;

  /// When non-null, the page is editing this existing built-in-
  /// backed [LocalProvider] instead of creating a new one.
  final LocalProvider? existing;

  final BuiltinModelDownloadService? _downloadService;

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
  /// completes successfully.
  String? _modelPath;
  String? _mmprojPath;

  int? _modelFileSize;
  ModelArchitecture? _modelArch;
  bool _archLoading = false;
  bool _saving = false;

  BuiltinModelDownloadState? _state;
  StreamSubscription<BuiltinModelDownloadState>? _sub;
  BuiltinModelDownloadService? _ownedDownloadService;

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
      _bootstrapDownloadService();
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

  BuiltinModelDownloadService _service() {
    final injected = widget._downloadService;
    if (injected != null) return injected;
    _ownedDownloadService ??= BuiltinModelDownloadService();
    return _ownedDownloadService!;
  }

  Future<void> _bootstrapDownloadService() async {
    final service = _service();
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
    _sub?.cancel();
    _name.dispose();
    _ownedDownloadService?.dispose();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final service = _service();
    setState(() {
      _state = null;
      _sub?.cancel();
    });
    // Re-read GGUF metadata from the freshly downloaded file so
    // the memory estimate card reflects the actual architecture.
    setState(() {
      _archLoading = true;
      _modelArch = null;
      _modelFileSize = null;
    });
    final completer = Completer<void>();
    _sub = service
        .download(widget.model)
        .listen(
          (s) {
            if (!mounted) return;
            setState(() => _state = s);
            if (s.isCompleted) {
              _modelPath = s.modelPath;
              _mmprojPath = s.mmprojPath;
              _refreshModelMetadata(s.modelPath!);
            }
            if (s.isTerminal && !completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
    await completer.future;
  }

  Future<void> _cancelDownload() async {
    _service().cancel(widget.model.id);
  }

  /// If the user backs out of the page mid-download, drop any
  /// half-written file so we don't leave a 1.5 GB orphan in the
  /// data dir. Best-effort — we don't block the pop on it.
  void _cleanupOnExit() {
    final state = _state;
    if (state == null) return;
    if (!state.isActive) return;
    unawaited(_service().cleanup(widget.model));
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
    setState(() => _saving = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = _state;
    final isEdit = _isEdit;
    // `canSave` is true once the files are on disk AND the
    // current run isn't in a failed/cancelled terminal state —
    // i.e. the user can hit Save.
    final canSave =
        _hasFilesOnDisk &&
        (state == null || state.isCompleted || !state.isActive) &&
        (state == null || !state.overallFailed);
    return PopScope(
      canPop: state == null || !state.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cleanupOnExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isEdit ? l10n.builtinModelEditTitle : widget.model.displayName,
          ),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _BuiltinHeader(
                model: widget.model,
                isEdit: isEdit,
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
              if (!isEdit) ...[
                _DownloadSection(
                  model: widget.model,
                  state: state,
                  onDownload: _startDownload,
                  onCancel: _cancelDownload,
                ),
                const SizedBox(height: 20),
              ] else ...[
                _InstalledFilesRow(
                  model: widget.model,
                  modelPath: _modelPath,
                  mmprojPath: _mmprojPath,
                  onRedownload: _startDownload,
                  state: state,
                ),
                const SizedBox(height: 20),
              ],
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
      ),
    );
  }
}

/// Top-of-page card showing the model name + one-line description
/// + a "约 X GB" size hint + a status pill ("已下载" / "已配置" /
/// "未配置"). Always visible so the user can read what they're
/// about to install or edit.
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

/// File picker replacement for the built-in flow. Renders one row
/// per file (model + optional mmproj) with a progress bar that
/// fills as bytes arrive, plus the Download / Cancel actions. The
/// two rows are independent in the UI but the underlying service
/// downloads them sequentially.
class _DownloadSection extends StatelessWidget {
  const _DownloadSection({
    required this.model,
    required this.state,
    required this.onDownload,
    required this.onCancel,
  });

  final BuiltinModel model;
  final BuiltinModelDownloadState? state;
  final VoidCallback onDownload;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = this.state;
    final showDownloadButton = state == null || state.isTerminal;
    final showCancelButton = state != null && state.isActive;
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
        Row(
          children: [
            if (showDownloadButton)
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text(l10n.builtinModelDownload),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            if (showCancelButton)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(l10n.builtinModelCancelDownload),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Shown in **edit** mode. Replaces the download section: the
/// files are already on disk (we wouldn't be in edit mode
/// otherwise) so we just show their paths + a re-download
/// affordance, no progress bar.
class _InstalledFilesRow extends StatelessWidget {
  const _InstalledFilesRow({
    required this.model,
    required this.modelPath,
    required this.mmprojPath,
    required this.onRedownload,
    required this.state,
  });

  final BuiltinModel model;
  final String? modelPath;
  final String? mmprojPath;
  final VoidCallback onRedownload;
  final BuiltinModelDownloadState? state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = this.state;
    final showRedownload = state == null || state.isTerminal;
    final showCancel = state != null && state.isActive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LocalProviderFormLabel(text: l10n.builtinModelFiles),
        _PathRow(label: l10n.builtinModelWeightsFile, path: modelPath),
        if (model.hasMmproj) ...[
          const SizedBox(height: 8),
          _PathRow(label: l10n.builtinModelMmprojFile, path: mmprojPath),
        ],
        if (state != null && state.isActive) ...[
          const SizedBox(height: 10),
          _LiveProgress(
            state: state,
            model: model,
            onCancel: showCancel ? onRedownload : null,
          ),
        ],
        if (state != null &&
            state.overall == BuiltinModelDownloadPhase.failed) ...[
          const SizedBox(height: 8),
          Text(
            l10n.builtinModelDownloadFailed(
              state.modelFile.error ?? state.mmprojFile?.error ?? '',
            ),
            style: const TextStyle(fontSize: 11, color: Color(0xFFD1242F)),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            if (showRedownload)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onRedownload,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: Text(l10n.builtinModelRedownload),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            if (showCancel)
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onRedownload,
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(l10n.builtinModelCancelDownload),
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.path});
  final String label;
  final String? path;

  @override
  Widget build(BuildContext context) {
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
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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

/// Live progress widget for the edit-mode "re-download" flow.
class _LiveProgress extends StatelessWidget {
  const _LiveProgress({
    required this.state,
    required this.model,
    required this.onCancel,
  });

  final BuiltinModelDownloadState state;
  final BuiltinModel model;
  final VoidCallback? onCancel;

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
          ),
        ],
      ],
    );
  }
}

/// One row inside [_DownloadSection] — filename + progress bar +
/// status. Three render modes:
///   * **idle / not yet started** — no progress bar, just a
///     "waiting" hint. This is the default before the user taps
///     "Download".
///   * **running** — determinate bar (when the server reported
///     Content-Length) or indeterminate bar (chunked transfer),
///     with a live byte counter underneath.
///   * **terminal** — completed / failed / cancelled. Completed
///     shows a 100% bar; failed / cancelled drop the bar and
///     surface the reason in a small line.
class _DownloadFileRow extends StatelessWidget {
  const _DownloadFileRow({
    required this.title,
    required this.file,
    required this.isCurrent,
    required this.isQueued,
  });

  final String title;
  final BuiltinFileDownload? file;
  final bool isCurrent;
  final bool isQueued;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final file = this.file;
    final fraction = file?.fraction;
    final status = file?.status ?? BuiltinFileStatus.pending;
    final statusLabel = _statusLabel(l10n, status);
    final statusColor = _statusColor(status);
    final filename = file?.filename ?? '';
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

  /// Picks the right visual for the file's current state. See
  /// the class docstring for the three render modes.
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

    // 2) Idle / pre-download state. We don't have a live
    // BuiltinFileDownload yet (state == null in the parent) OR
    // the file is sitting in `pending` waiting for its turn. No
    // bar — that's what was animating on its own before, looking
    // like a "ghost" download.
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
              l10n.builtinModelProgress(
                _bytesLabel(file.bytesReceived),
                _bytesLabel(file.bytesTotal),
              ),
              style: TextStyle(fontSize: 10, color: context.textSecondary),
            ),
          ],
        ],
      );
    }

    // 5) Running. Determinate if the server told us the size;
    // otherwise indeterminate (chunked transfer) with a running
    // byte counter.
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

  /// "123 MB / 1.7 GB" when the total is known, just "123 MB"
  /// when the server is using chunked transfer.
  String _progressLabel(
    AppLocalizations l10n,
    BuiltinFileDownload file,
    double? fraction,
  ) {
    if (file.bytesTotal > 0) {
      return l10n.builtinModelProgress(
        _bytesLabel(file.bytesReceived),
        _bytesLabel(file.bytesTotal),
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

extension on BuiltinModelDownloadState {
  bool get overallFailed => overall == BuiltinModelDownloadPhase.failed;
}
