import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/file_type.dart';
import '../models/provider.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class AddProviderPage extends StatefulWidget {
  const AddProviderPage({super.key, required this.settings, this.existing});

  final SettingsProvider settings;
  final ModelProvider? existing;

  @override
  State<AddProviderPage> createState() => _AddProviderPageState();
}

class _AddProviderPageState extends State<AddProviderPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _name;
  late TextEditingController _baseUrl;
  late TextEditingController _apiKey;
  late ProviderProtocol _protocol;
  late TextEditingController _chatPath;
  bool _obscure = true;
  bool _busy = false;
  List<String> _models = [];
  String? _selectedModel;

  /// The file categories the model accepts as inline base64.
  /// Defaults to [kDefaultSupportedFileTypes] (image only) for
  /// brand-new providers; existing rows round-trip their
  /// persisted set so the user doesn't lose what they had.
  late Set<AgentFileType> _supportedFileTypes;

  /// Whether to attach Anthropic-style `cache_control` markers
  /// to the wire payload when the active protocol is Anthropic.
  /// Defaults to `false` (matches the persisted model default).
  /// Only relevant for [ProviderProtocol.anthropic]; the form
  /// hides the toggle for OpenAI-protocol providers since
  /// OpenAI does not honour cache_control on its wire format.
  late bool _promptCacheEnabled;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _name = TextEditingController(text: p?.name ?? '');
    _protocol = p?.protocol ?? ProviderProtocol.openai;
    _baseUrl = TextEditingController(
      text: p?.baseUrl ?? _protocol.defaultBaseUrl,
    );
    _apiKey = TextEditingController(text: p?.apiKey ?? '');
    _chatPath = TextEditingController(
      text: p?.chatPath ?? _protocol.defaultPath,
    );
    _models = List.from(p?.models ?? const []);
    _selectedModel = p?.selectedModel;
    _supportedFileTypes = p == null
        ? {...kDefaultSupportedFileTypes}
        : {...p.effectiveSupportedFileTypes};
    _promptCacheEnabled = p?.promptCacheEnabled ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _chatPath.dispose();
    super.dispose();
  }

  void _onProtocolChange(ProviderProtocol? v) {
    if (v == null || v == _protocol) return;
    setState(() {
      _protocol = v;
      if (_baseUrl.text.trim() == _protocol.defaultBaseUrl ||
          _baseUrl.text.trim() == ProviderProtocol.openai.defaultBaseUrl ||
          _baseUrl.text.trim() == ProviderProtocol.anthropic.defaultBaseUrl) {
        _baseUrl.text = v.defaultBaseUrl;
      }
      _chatPath.text = v.defaultPath;
    });
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    final api = ApiService();
    final tmp = ModelProvider(
      id: 'tmp',
      name: _name.text.trim(),
      protocol: _protocol,
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      chatPath: _chatPath.text.trim(),
    );
    final ok = await api.testConnection(tmp);
    api.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.providerTestSuccess : l10n.providerTestFailed),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _fetchModels() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    final api = ApiService();
    final tmp = ModelProvider(
      id: 'tmp',
      name: _name.text.trim(),
      protocol: _protocol,
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      chatPath: _chatPath.text.trim(),
    );
    try {
      final models = await api.fetchModels(tmp);
      if (!mounted) return;
      setState(() {
        _models = models;
        if (_selectedModel == null || !models.contains(_selectedModel)) {
          _selectedModel = models.isNotEmpty ? models.first : null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.providerFetchSuccess(models.length)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.providerFetchFailed(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      api.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final apiKey = _apiKey.text.trim();
    final chatPath = _chatPath.text.trim();
    final existing = widget.existing;
    // Persist the explicit (possibly empty) set so the user can
    // intentionally disable every category. Only the legacy
    // "never persisted" rows keep the image-only default — we
    // round-trip that by writing the explicit set here.
    final supportedSnapshot = Set<AgentFileType>.unmodifiable(
      _supportedFileTypes,
    );
    if (existing == null) {
      final provider = await widget.settings.addProvider(
        name: name,
        protocol: _protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        chatPath: chatPath,
      );
      await widget.settings.updateProvider(
        provider.copyWith(
          models: _models,
          selectedModel: _selectedModel,
          supportedFileTypes: supportedSnapshot,
          promptCacheEnabled: _promptCacheEnabled,
        ),
      );
    } else {
      final updated = existing.copyWith(
        name: name,
        protocol: _protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        chatPath: chatPath,
        models: _models,
        selectedModel: _selectedModel,
        supportedFileTypes: supportedSnapshot,
        promptCacheEnabled: _promptCacheEnabled,
      );
      await widget.settings.updateProvider(updated);
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
              ? l10n.providerAddTitle
              : l10n.providerEditTitle,
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            _Label(text: l10n.providerProtocol),
            SegmentedButton<ProviderProtocol>(
              segments: [
                ButtonSegment(
                  value: ProviderProtocol.openai,
                  label: Text(l10n.providerProtocolOpenAI),
                  icon: const Icon(Icons.api, size: 16),
                ),
                ButtonSegment(
                  value: ProviderProtocol.anthropic,
                  label: Text(l10n.providerProtocolAnthropic),
                  icon: const Icon(Icons.psychology_alt, size: 16),
                ),
              ],
              selected: {_protocol},
              onSelectionChanged: (s) => _onProtocolChange(s.first),
            ),
            const SizedBox(height: 16),
            _Label(text: l10n.providerName),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(hintText: l10n.providerNameHint),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.providerNameRequired
                  : null,
            ),
            const SizedBox(height: 14),
            _Label(text: l10n.providerBaseUrl),
            TextFormField(
              controller: _baseUrl,
              decoration: InputDecoration(hintText: l10n.providerBaseUrlHint),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.providerBaseUrlRequired
                  : null,
            ),
            const SizedBox(height: 14),
            _Label(text: l10n.providerApiKey),
            TextFormField(
              controller: _apiKey,
              obscureText: _obscure,
              decoration: InputDecoration(
                hintText: l10n.providerApiKey,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.providerApiKeyRequired
                  : null,
            ),
            const SizedBox(height: 14),
            _Label(text: l10n.providerChatPath),
            TextFormField(
              controller: _chatPath,
              decoration: InputDecoration(
                hintText: _protocol.defaultPath,
                helperText: l10n.providerChatPathHelper,
                helperStyle: TextStyle(
                  fontSize: 11,
                  color: context.textSecondary,
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? l10n.providerChatPathRequired
                  : null,
            ),
            const SizedBox(height: 18),
            _SupportedFileTypesEditor(
              value: _supportedFileTypes,
              onChanged: (next) => setState(() {
                _supportedFileTypes = next;
              }),
            ),
            // Anthropic-only: prompt-cache (cache_control) toggle.
            // Hidden for the OpenAI protocol — OpenAI doesn't
            // honour cache_control on its wire format, so the
            // toggle would be meaningless / confusing.
            if (_protocol == ProviderProtocol.anthropic) ...[
              const SizedBox(height: 14),
              _PromptCacheSwitch(
                value: _promptCacheEnabled,
                onChanged: (v) => setState(() {
                  _promptCacheEnabled = v;
                }),
              ),
            ],
            SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: const Icon(Icons.wifi_tethering, size: 16),
                    label: Text(l10n.providerTestConnection),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _fetchModels,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.providerFetchModels),
                  ),
                ),
              ],
            ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 18),
              _Label(text: l10n.providerSelectModel),
              RadioGroup<String>(
                groupValue: _selectedModel,
                onChanged: (v) => setState(() => _selectedModel = v),
                child: Column(
                  children: _models.map((m) {
                    return RadioListTile<String>(
                      value: m,
                      title: Text(m, style: const TextStyle(fontSize: 13)),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    );
                  }).toList(),
                ),
              ),
            ],
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

/// Multi-select editor for [ModelProvider.supportedFileTypes].
///
/// Renders one chip per [AgentFileType] (text/image/audio/video/
/// document). Tapping a chip toggles it. The chip's color shifts
/// to the brand primary when active so the user can tell at a
/// glance which categories the model accepts inline. Helper text
/// explains the inline-vs-path-only tradeoff so the choice isn't
/// mysterious.
class _SupportedFileTypesEditor extends StatelessWidget {
  const _SupportedFileTypesEditor({
    required this.value,
    required this.onChanged,
  });

  final Set<AgentFileType> value;
  final ValueChanged<Set<AgentFileType>> onChanged;

  String _labelFor(BuildContext context, AgentFileType t) {
    final l10n = AppLocalizations.of(context);
    switch (t) {
      case AgentFileType.text:
        return l10n.providerFileTypeText;
      case AgentFileType.image:
        return l10n.providerFileTypeImage;
      case AgentFileType.audio:
        return l10n.providerFileTypeAudio;
      case AgentFileType.video:
        return l10n.providerFileTypeVideo;
      case AgentFileType.document:
        return l10n.providerFileTypeDocument;
    }
  }

  IconData _iconFor(AgentFileType t) {
    switch (t) {
      case AgentFileType.text:
        return Icons.text_snippet_outlined;
      case AgentFileType.image:
        return Icons.image_outlined;
      case AgentFileType.audio:
        return Icons.audiotrack_outlined;
      case AgentFileType.video:
        return Icons.movie_outlined;
      case AgentFileType.document:
        return Icons.description_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(text: l10n.providerSupportedFileTypes),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in AgentFileType.values)
              _FileTypeChip(
                label: _labelFor(context, t),
                icon: _iconFor(t),
                active: value.contains(t),
                // The `text` chip is pinned on. The wire layer
                // never inlines text bodies (it always emits a
                // `<attached_file path="…" />` reference), so the
                // toggle is purely cosmetic — surfacing it as a
                // disabled chip prevents the user from disabling
                // a category that has no behavioral effect, and
                // signals "yes, text files are handled" without
                // claiming more than the implementation actually
                // does.
                alwaysOn: t == AgentFileType.text,
                onTap: t == AgentFileType.text
                    ? null
                    : () {
                        final next = {...value};
                        if (!next.add(t)) next.remove(t);
                        onChanged(next);
                      },
              ),
          ],
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            l10n.providerSupportedFileTypesHelper,
            style: TextStyle(
              fontSize: 11,
              color: context.textSecondary,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _FileTypeChip extends StatelessWidget {
  const _FileTypeChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.alwaysOn = false,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback? onTap;

  /// When true, the chip renders in the disabled/greyed style
  /// and ignores taps regardless of [onTap]. Used for the
  /// always-on `text` chip so the user can see it without being
  /// able to toggle it. The visual treatment (muted palette +
  /// dashed border + lock-style icon) matches what the rest of
  /// the app uses for "non-interactive but visible" controls.
  final bool alwaysOn;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color border;
    final Color fg;
    final double borderWidth;
    final FontWeight fontWeight;
    final IconData trailingIcon;
    if (alwaysOn) {
      // Disabled / greyed-out treatment: muted background, dashed
      // border, lock icon trailing the label so the user can tell
      // at a glance that this category is pinned and not
      // user-controllable.
      bg = context.surface;
      border = context.appBorder;
      fg = context.textSecondary.withValues(alpha: 0.7);
      borderWidth = 0.6;
      fontWeight = FontWeight.w500;
      trailingIcon = Icons.lock_outline;
    } else if (active) {
      bg = AppTheme.primary.withValues(alpha: 0.10);
      border = AppTheme.primary;
      fg = AppTheme.primary;
      borderWidth = 1.0;
      fontWeight = FontWeight.w600;
      trailingIcon = Icons.check_circle;
    } else {
      bg = context.surface;
      border = context.appBorder;
      fg = context.textSecondary;
      borderWidth = 0.6;
      fontWeight = FontWeight.w500;
      trailingIcon = Icons.circle_outlined;
    }
    return Tooltip(
      message: alwaysOn
          ? 'Always on — text files are always sent as path references.'
          : label,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: border, width: borderWidth),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: fg,
                    fontWeight: fontWeight,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(trailingIcon, size: 14, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Prompt-cache toggle for the Anthropic protocol. Switches
/// the [ModelProvider.promptCacheEnabled] flag on / off; the
/// wire layer reads it when building the Anthropic payload
/// and attaches `cache_control: {type: ephemeral}` to the last
/// tool / system / user-message block.
///
/// No-op for the OpenAI protocol (the toggle is hidden on the
/// AddProviderPage for that protocol). Defaults to off so
/// legacy OpenAI-compatible providers that silently drop
/// unknown fields keep behaving identically.
class _PromptCacheSwitch extends StatelessWidget {
  const _PromptCacheSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(text: l10n.providerPromptCache),
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(horizontal: 2),
          value: value,
          onChanged: onChanged,
          // Compress the default SwitchListTile vertical padding
          // — the toggle row sits between the supported-file-types
          // editor and the test/fetch button row, and the default
          // 24px+ padding makes the form noticeably taller.
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(
            l10n.providerPromptCache,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              l10n.providerPromptCacheHelper,
              style: TextStyle(
                fontSize: 11,
                color: context.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
