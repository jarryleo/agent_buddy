import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../models/local_provider.dart';
import '../providers/settings_provider.dart';
import '../services/gguf_metadata.dart';
import '../theme/app_theme.dart';
import 'widgets/local_provider_form_fields.dart';

class AddLocalProviderPage extends StatefulWidget {
  const AddLocalProviderPage({
    super.key,
    required this.settings,
    this.existing,
  });

  final SettingsProvider settings;
  final LocalProvider? existing;

  @override
  State<AddLocalProviderPage> createState() => _AddLocalProviderPageState();
}

class _AddLocalProviderPageState extends State<AddLocalProviderPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _name;
  late TextEditingController _modelPath;
  TextEditingController? _mmprojPath;
  late int _contextSize;
  late double _temperature;
  late int _gpuLayers;
  late int _maxTokens;
  late String _cacheTypeK;
  late String _cacheTypeV;
  late int _batchSize;
  late int? _thinkingBudgetTokens;

  int? _modelFileSize;
  ModelArchitecture? _modelArch;
  bool _archLoading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _name = TextEditingController(text: p?.name ?? '');
    _modelPath = TextEditingController(text: p?.modelPath ?? '');
    _mmprojPath = TextEditingController(text: p?.mmprojPath ?? '');
    _contextSize = p?.contextSize ?? 4096;
    _temperature = p?.temperature ?? 0.7;
    _gpuLayers = p?.gpuLayers ?? 0;
    _maxTokens = p?.maxTokens ?? 1024;
    final defaultK = _defaultKvCacheTypeK();
    final defaultV = _defaultKvCacheTypeV();
    _cacheTypeK = p?.cacheTypeK ?? defaultK;
    _cacheTypeV = p?.cacheTypeV ?? defaultV;
    _batchSize = p?.batchSize ?? LocalProvider.kDefaultBatchSize;
    _thinkingBudgetTokens = p?.thinkingBudgetTokens;
    if (_modelPath.text.trim().isNotEmpty) {
      _refreshModelMetadata(_modelPath.text.trim());
    }
  }

  /// On mobile the RAM and VRAM budgets are usually much smaller than
  /// on a desktop, so we default to q8_0 (K) + q4_0 (V) to give the
  /// model a fighting chance at larger context windows. Desktop / web
  /// keep the llama.cpp default of f16 for max quality. Users can
  /// still override either value explicitly.
  static bool get _isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS;
  }

  static String _defaultKvCacheTypeK() => _isMobile ? 'q8_0' : 'f16';

  static String _defaultKvCacheTypeV() => _isMobile ? 'q4_0' : 'f16';

  @override
  void dispose() {
    _name.dispose();
    _modelPath.dispose();
    _mmprojPath?.dispose();
    super.dispose();
  }

  Future<FilePickerResult?> _pickFile({required bool allowGgufOnly}) async {
    try {
      if (!allowGgufOnly ||
          kIsWeb ||
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux) {
        return await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['gguf'],
          withData: kIsWeb,
        );
      }
      // Android (and iOS) FilePicker doesn't know the GGUF MIME type, so
      // requesting `FileType.custom` with `allowedExtensions: ['gguf']`
      // throws `Unsupported filter`. Fall back to `FileType.any` and
      // filter client-side.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: kIsWeb,
      );
      if (result == null) return null;
      result.files.retainWhere((f) => f.extension?.toLowerCase() == 'gguf');
      return result.files.isEmpty ? null : result;
    } on PlatformException catch (e) {
      if (e.code == 'unsupported_filter' ||
          e.message?.contains('Unsupported filter') == true) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          withData: kIsWeb,
        );
        if (result == null) return null;
        result.files.retainWhere((f) => f.extension?.toLowerCase() == 'gguf');
        return result.files.isEmpty ? null : result;
      }
      rethrow;
    }
  }

  Future<void> _pickModelFile() async {
    try {
      final result = await _pickFile(allowGgufOnly: true);
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path == null) return;
      setState(() {
        _modelPath.text = path;
        if (_name.text.trim().isEmpty) {
          _name.text = p.basenameWithoutExtension(path);
        }
        // Try to auto-detect an mmproj in the same directory.
        final detected = _autoDetectMmproj(path);
        if (detected != null) {
          _mmprojPath?.text = detected;
        }
      });
      await _refreshModelMetadata(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Read the GGUF header (architecture fields) and the file size for
  /// the memory estimate. Both are best-effort — if either fails we
  /// fall back to file-size-based heuristics in the estimator.
  Future<void> _refreshModelMetadata(String path) async {
    if (kIsWeb) {
      setState(() {
        _modelFileSize = null;
        _modelArch = null;
      });
      return;
    }
    setState(() {
      _archLoading = true;
      _modelArch = null;
      _modelFileSize = null;
    });
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

  Future<void> _pickMmprojFile() async {
    try {
      final result = await _pickFile(allowGgufOnly: true);
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path == null) return;
      setState(() {
        _mmprojPath?.text = path;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String? _autoDetectMmproj(String modelPath) {
    if (kIsWeb) return null;
    final dir = p.dirname(modelPath);
    final dirHandle = Directory(dir);
    if (!dirHandle.existsSync()) return null;
    final baseName = p.basenameWithoutExtension(modelPath).toLowerCase();
    for (final entity in dirHandle.listSync()) {
      if (entity is! File) continue;
      final name = entity.path.toLowerCase();
      if (name.contains('mmproj') && name.endsWith('.gguf')) {
        return entity.path;
      }
    }
    // Fallback: some bundles store the projector with a name derived from the
    // model name (e.g. Qwen2.5-VL-7B-Instruct-mmproj.gguf). Already covered by
    // the generic `mmproj` search above, but we also accept base-name-prefixed
    // projectors.
    for (final entity in dirHandle.listSync()) {
      if (entity is! File) continue;
      final name = entity.path.toLowerCase();
      if (name.endsWith('.gguf') &&
          name.contains(baseName) &&
          name.contains('mmproj')) {
        return entity.path;
      }
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final name = _name.text.trim();
    final modelPath = _modelPath.text.trim();
    final mmproj = _mmprojPath?.text.trim();
    try {
      if (!kIsWeb && !File(modelPath).existsSync()) {
        throw Exception(
          AppLocalizations.of(context).localProviderFileMissing(modelPath),
        );
      }
    } catch (_) {
      // On web, File.existsSync is unavailable; the engine will fail
      // later if the path is invalid.
    }
    if (!kIsWeb &&
        mmproj != null &&
        mmproj.isNotEmpty &&
        !File(mmproj).existsSync()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).localProviderFileMissing(mmproj),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      setState(() => _busy = false);
      return;
    }
    final existing = widget.existing;
    if (existing == null) {
      await widget.settings.addLocalProvider(
        name: name,
        modelPath: modelPath,
        mmprojPath: (mmproj == null || mmproj.isEmpty) ? null : mmproj,
        contextSize: _contextSize,
        temperature: _temperature,
        gpuLayers: _gpuLayers,
        maxTokens: _maxTokens,
        cacheTypeK: _cacheTypeK,
        cacheTypeV: _cacheTypeV,
        batchSize: _batchSize,
        thinkingBudgetTokens: _thinkingBudgetTokens,
      );
    } else {
      await widget.settings.updateLocalProvider(
        existing.copyWith(
          name: name,
          modelPath: modelPath,
          mmprojPath: (mmproj == null || mmproj.isEmpty) ? null : mmproj,
          contextSize: _contextSize,
          temperature: _temperature,
          gpuLayers: _gpuLayers,
          maxTokens: _maxTokens,
          cacheTypeK: _cacheTypeK,
          cacheTypeV: _cacheTypeV,
          batchSize: _batchSize,
          thinkingBudgetTokens: _thinkingBudgetTokens,
        ),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null
              ? l10n.localProviderAddTitle
              : l10n.localProviderEditTitle,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            LocalProviderFormLabel(text: l10n.localProviderName),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(hintText: l10n.localProviderNameHint),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.localProviderNameRequired
                  : null,
            ),
            const SizedBox(height: 14),
            LocalProviderFormLabel(text: l10n.localProviderModelFile),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _modelPath,
                    decoration: InputDecoration(
                      hintText: l10n.localProviderModelFile,
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return l10n.localProviderModelFileRequired;
                      }
                      if (!kIsWeb && !File(v.trim()).existsSync()) {
                        return l10n.localProviderFileMissing(v.trim());
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickModelFile,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: Text(l10n.localProviderPickModelFile),
                ),
              ],
            ),
            const SizedBox(height: 14),
            LocalProviderFormLabel(text: l10n.localProviderMmprojFile),
            Text(
              l10n.localProviderMmprojHint,
              style: TextStyle(
                fontSize: 11,
                color: context.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _mmprojPath,
                    decoration: InputDecoration(
                      hintText: l10n.localProviderMmprojFile,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _pickMmprojFile,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: Text(l10n.localProviderPickMmproj),
                ),
              ],
            ),
            if (_mmprojPath != null && _mmprojPath!.text.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _mmprojPath?.clear()),
                  icon: const Icon(Icons.clear, size: 14),
                  label: Text(l10n.localProviderClearMmproj),
                ),
              ),
            ],
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
            const SizedBox(height: 16),
            ThinkingBudgetSlider(
              value: _thinkingBudgetTokens,
              presets: LocalProviderPresets.thinkingBudget,
              onChanged: (v) => setState(() => _thinkingBudgetTokens = v),
              label: l10n.localProviderThinkingBudget,
              noLimitLabel: l10n.localProviderThinkingBudgetNoLimit,
              hint: l10n.localProviderThinkingBudgetHint,
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 46,
              child: ElevatedButton(
                onPressed: _busy ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _busy
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
  }
}
