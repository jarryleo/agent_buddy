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
import '../services/memory_estimator.dart';
import '../theme/app_theme.dart';

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

  int? _modelFileSize;
  ModelArchitecture? _modelArch;
  bool _archLoading = false;
  bool _busy = false;

  static const _contextPresets = <int>[
    512,
    1024,
    2048,
    4096,
    8192,
    16384,
    32768,
    65536,
    131072,
  ];
  static const _maxTokensPresets = <int>[128, 256, 512, 1024, 2048, 4096];
  static const _batchSizePresets = <int>[256, 512, 1024, 2048, 4096];

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
            _Label(text: l10n.localProviderName),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(hintText: l10n.localProviderNameHint),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.localProviderNameRequired
                  : null,
            ),
            const SizedBox(height: 14),
            _Label(text: l10n.localProviderModelFile),
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
            _Label(text: l10n.localProviderMmprojFile),
            Text(
              l10n.localProviderMmprojHint,
              style: TextStyle(
                fontSize: 11,
                color: context.textSecondary,
                height: 1.4,
              ),
            ),
            SizedBox(height: 6),
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
            _MemoryEstimateCard(
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
            _Label(text: l10n.localProviderParams),
            const SizedBox(height: 4),
            _ContextSizeSlider(
              value: _contextSize,
              presets: _contextPresets,
              onChanged: (v) => setState(() => _contextSize = v),
              label: l10n.localProviderContextSize,
            ),
            const SizedBox(height: 16),
            _SliderField(
              value: _temperature,
              min: 0.0,
              max: 2.0,
              divisions: 40,
              onChanged: (v) => setState(() => _temperature = v),
              label: l10n.localProviderTemperature,
              display: _temperature.toStringAsFixed(2),
            ),
            const SizedBox(height: 16),
            _GpuLayersField(
              value: _gpuLayers,
              onChanged: (v) => setState(() => _gpuLayers = v),
              label: l10n.localProviderGpuLayers,
              hint: l10n.localProviderGpuLayersHint,
            ),
            const SizedBox(height: 16),
            _MaxTokensSlider(
              value: _maxTokens,
              presets: _maxTokensPresets,
              onChanged: (v) => setState(() => _maxTokens = v),
              label: l10n.localProviderMaxTokens,
            ),
            const SizedBox(height: 16),
            _KvCacheTypeField(
              label: l10n.localProviderKvCacheK,
              hint: l10n.localProviderKvCacheHint,
              value: _cacheTypeK,
              onChanged: (v) => setState(() => _cacheTypeK = v),
            ),
            const SizedBox(height: 12),
            _KvCacheTypeField(
              label: l10n.localProviderKvCacheV,
              hint: null,
              value: _cacheTypeV,
              onChanged: (v) => setState(() => _cacheTypeV = v),
            ),
            const SizedBox(height: 16),
            _BatchSizeSlider(
              value: _batchSize,
              presets: _batchSizePresets,
              onChanged: (v) => setState(() => _batchSize = v),
              label: l10n.localProviderBatchSize,
              hint: l10n.localProviderBatchSizeHint,
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

class _Label extends StatelessWidget {
  const _Label({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.textSecondary,
        ),
      ),
    );
  }
}

class _ContextSizeSlider extends StatelessWidget {
  const _ContextSizeSlider({
    required this.value,
    required this.presets,
    required this.onChanged,
    required this.label,
  });

  final int value;
  final List<int> presets;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ),
            Text(
              '$value',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: presets.contains(value)
              ? presets.indexOf(value).toDouble()
              : 0,
          min: 0,
          max: (presets.length - 1).toDouble(),
          divisions: presets.length - 1,
          label: '$value',
          onChanged: (v) => onChanged(presets[v.round()]),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: presets
              .map(
                (p) => Text(
                  '$p',
                  style: TextStyle(fontSize: 10, color: context.textSecondary),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _MaxTokensSlider extends StatelessWidget {
  const _MaxTokensSlider({
    required this.value,
    required this.presets,
    required this.onChanged,
    required this.label,
  });

  final int value;
  final List<int> presets;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ),
            Text(
              '$value',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: presets.contains(value)
              ? presets.indexOf(value).toDouble()
              : 0,
          min: 0,
          max: (presets.length - 1).toDouble(),
          divisions: presets.length - 1,
          label: '$value',
          onChanged: (v) => onChanged(presets[v.round()]),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: presets
              .map(
                (p) => Text(
                  '$p',
                  style: TextStyle(fontSize: 10, color: context.textSecondary),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _SliderField extends StatelessWidget {
  const _SliderField({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.label,
    required this.display,
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final String label;
  final String display;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ),
            Text(
              display,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: display,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _GpuLayersField extends StatefulWidget {
  const _GpuLayersField({
    required this.value,
    required this.onChanged,
    required this.label,
    required this.hint,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final String label;
  final String hint;

  @override
  State<_GpuLayersField> createState() => _GpuLayersFieldState();
}

class _GpuLayersFieldState extends State<_GpuLayersField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(covariant _GpuLayersField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value.toString() != _controller.text) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ),
            SizedBox(
              width: 70,
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.right,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 8,
                  ),
                ),
                onChanged: (v) {
                  final parsed = int.tryParse(v.trim());
                  if (parsed != null && parsed >= 0) {
                    widget.onChanged(parsed);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          widget.hint,
          style: TextStyle(fontSize: 10, color: context.textSecondary),
        ),
      ],
    );
  }
}

class _KvCacheTypeField extends StatelessWidget {
  const _KvCacheTypeField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;

  static const _options = <String>['f16', 'q8_0', 'q4_0'];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ),
            DropdownButton<String>(
              value: value,
              isDense: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final opt in _options)
                  DropdownMenuItem(value: opt, child: Text(opt)),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(
            hint!,
            style: TextStyle(fontSize: 10, color: context.textSecondary),
          ),
        ],
      ],
    );
  }
}

class _BatchSizeSlider extends StatelessWidget {
  const _BatchSizeSlider({
    required this.value,
    required this.presets,
    required this.onChanged,
    required this.label,
    this.hint,
  });

  final int value;
  final List<int> presets;
  final ValueChanged<int> onChanged;
  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final safeValue = presets.contains(value)
        ? value
        : LocalProvider.kDefaultBatchSize;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSecondary,
                ),
              ),
            ),
            Text(
              '$value',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: presets.indexOf(safeValue).toDouble(),
          min: 0,
          max: (presets.length - 1).toDouble(),
          divisions: presets.length - 1,
          label: '$value',
          onChanged: (v) => onChanged(presets[v.round()]),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: presets
              .map(
                (p) => Text(
                  '$p',
                  style: TextStyle(fontSize: 10, color: context.textSecondary),
                ),
              )
              .toList(),
        ),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(
            hint!,
            style: TextStyle(fontSize: 10, color: context.textSecondary),
          ),
        ],
      ],
    );
  }
}

class _MemoryEstimateCard extends StatelessWidget {
  const _MemoryEstimateCard({
    required this.modelFileSize,
    required this.arch,
    required this.loading,
    required this.contextSize,
    required this.batchSize,
    required this.cacheTypeK,
    required this.cacheTypeV,
    required this.modelLabel,
    required this.kvLabel,
    required this.computeLabel,
    required this.totalLabel,
    required this.missingLabel,
    required this.loadingLabel,
  });

  final int? modelFileSize;
  final ModelArchitecture? arch;
  final bool loading;
  final int contextSize;
  final int batchSize;
  final String cacheTypeK;
  final String cacheTypeV;
  final String modelLabel;
  final String kvLabel;
  final String computeLabel;
  final String totalLabel;
  final String missingLabel;
  final String loadingLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: context.textSecondary.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading) ...[
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                const SizedBox(width: 8),
                Text(
                  loadingLabel,
                  style: TextStyle(fontSize: 11, color: context.textSecondary),
                ),
              ],
            ),
          ] else if (modelFileSize == null) ...[
            Text(
              missingLabel,
              style: TextStyle(fontSize: 11, color: context.textSecondary),
            ),
          ] else ...[
            _row(
              context,
              totalLabel,
              formatBytes(_breakdown.totalBytes),
              emphasize: true,
            ),
            const SizedBox(height: 4),
            _row(context, modelLabel, formatBytes(_breakdown.modelFileBytes)),
            _row(context, kvLabel, formatBytes(_breakdown.kvCacheBytes)),
            _row(
              context,
              computeLabel,
              formatBytes(_breakdown.computeBufferBytes),
            ),
          ],
        ],
      ),
    );
  }

  MemoryBreakdown get _breakdown {
    return const MemoryEstimator().estimate(
      modelFileBytes: modelFileSize ?? 0,
      arch: arch,
      contextSize: contextSize,
      batchSize: batchSize,
      cacheTypeK: cacheTypeK,
      cacheTypeV: cacheTypeV,
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool emphasize = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: emphasize ? 12 : 11,
                color: context.textSecondary,
                fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: emphasize ? 13 : 11,
              color: context.textPrimary,
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
