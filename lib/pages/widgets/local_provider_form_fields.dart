import 'package:flutter/material.dart';

import '../../models/local_provider.dart';
import '../../services/gguf_metadata.dart';
import '../../services/memory_estimator.dart';
import '../../theme/app_colors.dart';

/// Small field label shared by the add-local-provider form and the
/// built-in model download form. The two pages use identical label
/// styling so we render the same row from one place.
class LocalProviderFormLabel extends StatelessWidget {
  const LocalProviderFormLabel({super.key, required this.text});
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

/// Context-size slider with preset tick marks. Used by both the
/// add-local-provider form and the built-in model download form.
class ContextSizeSlider extends StatelessWidget {
  const ContextSizeSlider({
    super.key,
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
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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

/// Max-tokens slider with preset tick marks.
class MaxTokensSlider extends StatelessWidget {
  const MaxTokensSlider({
    super.key,
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
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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

/// Generic continuous slider with a label + right-aligned live
/// display. Used for temperature and similar knobs.
class SliderField extends StatelessWidget {
  const SliderField({
    super.key,
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
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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

/// GPU-layers row: label + numeric text input. Validation is
/// non-negative integers; bad input is silently ignored.
class GpuLayersField extends StatefulWidget {
  const GpuLayersField({
    super.key,
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
  State<GpuLayersField> createState() => _GpuLayersFieldState();
}

class _GpuLayersFieldState extends State<GpuLayersField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.value}');
  }

  @override
  void didUpdateWidget(covariant GpuLayersField oldWidget) {
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
                decoration: const InputDecoration(
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

/// KV-cache quantization dropdown (f16 / q8_0 / q4_0). The set of
/// options is fixed at the llama.cpp level so we don't expose it
/// to the caller.
class KvCacheTypeField extends StatelessWidget {
  const KvCacheTypeField({
    super.key,
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

/// n_batch slider with preset tick marks. Falls back to the safe
/// default when the persisted value isn't in the preset list (older
/// config or a value the user typed in by hand).
class BatchSizeSlider extends StatelessWidget {
  const BatchSizeSlider({
    super.key,
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
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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

/// Reasoning-budget slider with preset tick marks. The leftmost
/// tick is `0` ("不限" / "no cap"); the right side shows the
/// current value with the same formatting as [MaxTokensSlider].
///
/// `0` is rendered as the localized "no budget" label (passed via
/// [noLimitLabel]) so the user understands that the first tick
/// doesn't mean "0 reasoning tokens" — it disables llama.cpp's
/// reasoning-budget sampler entirely (legacy behavior).
class ThinkingBudgetSlider extends StatelessWidget {
  const ThinkingBudgetSlider({
    super.key,
    required this.value,
    required this.presets,
    required this.onChanged,
    required this.label,
    required this.noLimitLabel,
    this.hint,
  });

  final int? value;
  final List<int> presets;
  final ValueChanged<int?> onChanged;
  final String label;
  final String noLimitLabel;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    // Persisted `null` is mapped to the leftmost "no budget" tick
    // (`0`). Persisted values that aren't in the preset list (older
    // config or a typed-in number) snap to the closest preset so
    // the slider's state stays consistent.
    final clamped = (value == null || value! <= 0) ? 0 : value!;
    final safeValue = presets.contains(clamped) ? clamped : presets.last;
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
              safeValue == 0 ? noLimitLabel : '$safeValue',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: presets.indexOf(safeValue).toDouble(),
          min: 0,
          max: (presets.length - 1).toDouble(),
          divisions: presets.length - 1,
          label: safeValue == 0 ? noLimitLabel : '$safeValue',
          onChanged: (v) {
            final picked = presets[v.round()];
            // `0` is the "no budget" sentinel — round-trip via
            // `null` so the JSON we persist clearly says
            // "no reasoning-budget" instead of the placeholder
            // "0 tokens of reasoning".
            onChanged(picked == 0 ? null : picked);
          },
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: presets
              .map(
                (p) => Text(
                  p == 0 ? noLimitLabel : '$p',
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

/// Estimate of the RAM/VRAM budget a model + KV cache + compute
/// buffer will need, given the user's tuning. Reads the GGUF
/// header (best effort) and falls back to a size-only heuristic
/// when the file is unreadable.
class MemoryEstimateCard extends StatelessWidget {
  const MemoryEstimateCard({
    super.key,
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

/// Presets shared by the add-local-provider form and the built-in
/// model download form. Kept here so the two pages stay in sync
/// when the supported list changes.
class LocalProviderPresets {
  LocalProviderPresets._();
  static const List<int> contextSize = <int>[
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
  static const List<int> maxTokens = <int>[128, 256, 512, 1024, 2048, 4096];
  static const List<int> batchSize = <int>[256, 512, 1024, 2048, 4096];

  /// Reasoning-block budget presets in tokens. The leading `0`
  /// maps to "no budget" (legacy behavior — reasoning can run
  /// until the model decides to stop or the context runs out).
  /// The other values are reasonable caps for thinking models on
  /// 4K–32K context windows. llama.cpp accepts 0 through
  /// 2,147,483,647; the largest preset here (16K) is enough for
  /// any sensible interactive chat.
  static const List<int> thinkingBudget = <int>[
    0,
    1024,
    2048,
    4096,
    8192,
    16384,
  ];
}
