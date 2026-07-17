import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/builtin_model.dart';
import '../models/local_provider.dart';
import '../models/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';
import 'add_local_provider_page.dart';
import 'add_provider_page.dart';
import 'builtin_model_download_page.dart';
import 'settings_page.dart';

class ProvidersTab extends StatelessWidget {
  const ProvidersTab({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SettingsProvider settings;
  final VoidCallback onChanged;

  Future<void> _openAdd(BuildContext context) async {
    if (settings.useLocalModel) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AddLocalProviderPage(settings: settings),
        ),
      );
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AddProviderPage(settings: settings)),
      );
    }
    onChanged();
  }

  Future<void> _openEditCloud(BuildContext context, ModelProvider p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddProviderPage(settings: settings, existing: p),
      ),
    );
    onChanged();
  }

  Future<void> _openEditLocal(BuildContext context, LocalProvider p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddLocalProviderPage(settings: settings, existing: p),
      ),
    );
    onChanged();
  }

  Future<void> _openBuiltinDownload(
    BuildContext context,
    BuiltinModel model, [
    LocalProvider? existing,
  ]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BuiltinModelDownloadPage(
          settings: settings,
          model: model,
          existing: existing,
        ),
      ),
    );
    onChanged();
  }

  Future<void> _testConnection(BuildContext context, ModelProvider p) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.providerTesting),
        duration: const Duration(seconds: 1),
      ),
    );
    final api = ApiService();
    final ok = await api.testConnection(p);
    api.dispose();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? l10n.providerTestSuccess : l10n.providerTestFailed),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _fetchModels(BuildContext context, ModelProvider p) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final api = ApiService();
    try {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.providerFetching),
          duration: const Duration(seconds: 1),
        ),
      );
      final models = await api.fetchModels(p);
      final updated = p.copyWith(models: models);
      await settings.updateProvider(updated);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.providerFetchSuccess(models.length)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.providerFetchFailed(e.toString())),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      api.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final useLocal = settings.useLocalModel;
    return Scaffold(
      backgroundColor: context.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAdd(context),
        icon: Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _ModeSwitcher(
            useLocal: useLocal,
            onChanged: (v) => settings.setUseLocalModel(v),
            l10n: l10n,
          ),
          Expanded(
            child: useLocal
                ? _LocalList(
                    settings: settings,
                    l10n: l10n,
                    onChanged: onChanged,
                    onEdit: (p) => _openEditLocal(context, p),
                    onOpenBuiltinDownload: (m, existing) =>
                        _openBuiltinDownload(context, m, existing),
                  )
                : _CloudList(
                    settings: settings,
                    l10n: l10n,
                    onChanged: onChanged,
                    onEdit: (p) => _openEditCloud(context, p),
                    onTest: (p) => _testConnection(context, p),
                    onFetch: (p) => _fetchModels(context, p),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CloudList extends StatelessWidget {
  const _CloudList({
    required this.settings,
    required this.l10n,
    required this.onChanged,
    required this.onEdit,
    required this.onTest,
    required this.onFetch,
  });

  final SettingsProvider settings;
  final AppLocalizations l10n;
  final VoidCallback onChanged;
  final ValueChanged<ModelProvider> onEdit;
  final ValueChanged<ModelProvider> onTest;
  final ValueChanged<ModelProvider> onFetch;

  @override
  Widget build(BuildContext context) {
    final providers = settings.providers;
    if (providers.isEmpty) {
      return EmptyHint(
        text: l10n.providerListEmpty,
        icon: Icons.cloud_outlined,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      itemCount: providers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final p = providers[index];
        return _ProviderCard(
          provider: p,
          isActive: settings.activeProviderId == p.id,
          l10n: l10n,
          onTap: () => onEdit(p),
          onToggle: (v) => settings.toggleProvider(p.id, v),
          onSetActive: () => settings.setActiveProvider(p.id),
          onTest: () => onTest(p),
          onFetch: () => onFetch(p),
          onDelete: () async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l10n.providerDeleteTitle),
                content: Text(l10n.providerDeleteConfirm(p.name)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(l10n.commonCancel),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(l10n.commonDelete),
                  ),
                ],
              ),
            );
            if (confirm == true) {
              await settings.deleteProvider(p.id);
              onChanged();
            }
          },
        );
      },
    );
  }
}

class _LocalList extends StatelessWidget {
  const _LocalList({
    required this.settings,
    required this.l10n,
    required this.onChanged,
    required this.onEdit,
    required this.onOpenBuiltinDownload,
  });

  final SettingsProvider settings;
  final AppLocalizations l10n;
  final VoidCallback onChanged;
  final ValueChanged<LocalProvider> onEdit;
  final void Function(BuiltinModel model, LocalProvider? existing)
  onOpenBuiltinDownload;

  @override
  Widget build(BuildContext context) {
    // Only show user-added (non-built-in) local providers here.
    // Built-in providers are surfaced by the [BuiltinModelCard]s
    // below — we don't want the same model to appear twice.
    final providers = settings.customLocalProviders;
    final builtins = BuiltinModels.all;
    if (providers.isEmpty && builtins.isEmpty) {
      return EmptyHint(
        text: l10n.localProviderListEmpty,
        icon: Icons.memory_outlined,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      children: [
        for (var i = 0; i < providers.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _LocalProviderCard(
            provider: providers[i],
            isActive: settings.activeLocalProviderId == providers[i].id,
            l10n: l10n,
            onTap: () => onEdit(providers[i]),
            onToggle: (v) => settings.toggleLocalProvider(providers[i].id, v),
            onSetActive: () => settings.setActiveLocalProvider(providers[i].id),
            onDelete: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(l10n.localProviderDeleteTitle),
                  content: Text(
                    l10n.localProviderDeleteConfirm(providers[i].name),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(l10n.commonCancel),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(l10n.commonDelete),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await settings.deleteLocalProvider(providers[i].id);
                onChanged();
              }
            },
          ),
        ],
        if (builtins.isNotEmpty) ...[
          if (providers.isNotEmpty) const SizedBox(height: 20),
          _BuiltInModelsSection(
            settings: settings,
            l10n: l10n,
            onOpen: onOpenBuiltinDownload,
          ),
        ],
      ],
    );
  }
}

/// Renders a section header + one card per [BuiltinModel] entry.
/// Each card surfaces "configured / not configured" status (we
/// use the linked [LocalProvider] for that, not the file system —
/// the user hasn't actually "installed" the model until they
/// save the parameter form) and opens the
/// [BuiltinModelDownloadPage] in the right mode on tap.
class _BuiltInModelsSection extends StatefulWidget {
  const _BuiltInModelsSection({
    required this.settings,
    required this.l10n,
    required this.onOpen,
  });

  final SettingsProvider settings;
  final AppLocalizations l10n;
  final void Function(BuiltinModel model, LocalProvider? existing) onOpen;

  @override
  State<_BuiltInModelsSection> createState() => _BuiltInModelsSectionState();
}

class _BuiltInModelsSectionState extends State<_BuiltInModelsSection> {
  @override
  Widget build(BuildContext context) {
    final builtins = BuiltinModels.all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(widget.l10n.builtinModelSectionTitle),
        for (var i = 0; i < builtins.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          Builder(
            builder: (context) {
              final provider = widget.settings.localProviderForBuiltin(
                builtins[i].id,
              );
              return _BuiltinModelCard(
                model: builtins[i],
                configured: provider != null,
                provider: provider,
                isActive:
                    provider != null &&
                    widget.settings.activeLocalProviderId == provider.id,
                onTap: () => widget.onOpen(builtins[i], provider),
                onToggle: provider == null
                    ? (_) {}
                    : (v) =>
                          widget.settings.toggleLocalProvider(provider.id, v),
                onSetActive: provider == null
                    ? () {}
                    : () => widget.settings.setActiveLocalProvider(provider.id),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// Single row in the built-in models section. Three states:
///   * **not configured** — icon + name + "未配置" pill, tap
///     opens the download page.
///   * **configured, inactive** — same shape plus a Switch (the
///     user-added card has one too) and a "设为默认" button.
///   * **active** — same as above, but the card border thickens
///     and a "使用中" pill is rendered next to the name.
class _BuiltinModelCard extends StatelessWidget {
  const _BuiltinModelCard({
    required this.model,
    required this.configured,
    required this.provider,
    required this.isActive,
    required this.onTap,
    required this.onToggle,
    required this.onSetActive,
  });

  final BuiltinModel model;

  /// Whether the user has finished the download + configure flow
  /// for this built-in model. Drives the action row visibility.
  final bool configured;

  /// The linked [LocalProvider] when [configured] is `true`. Used
  /// for the Switch + "设为默认" button. `null` when not configured.
  final LocalProvider? provider;

  /// Whether the linked provider is the active one. The card
  /// border + "使用中" pill reflect this.
  final bool isActive;

  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSetActive;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Material(
      color: context.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? AppTheme.primary : context.appBorder,
              width: isActive ? 1.4 : 0.6,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      configured ? Icons.tune : Icons.cloud_download_outlined,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                provider?.name ?? model.displayName,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  l10n.commonInUse,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          configured
                              ? (provider?.displayModelName ??
                                    model.description)
                              : model.description,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (configured && provider != null)
                    Switch(value: provider!.enabled, onChanged: onToggle)
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        l10n.builtinModelNotConfigured,
                        style: TextStyle(
                          color: AppTheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              if (configured && provider != null) ...[
                if (provider!.mmprojPath != null &&
                    provider!.mmprojPath!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 14,
                        color: context.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          provider!.mmprojPath!.split(RegExp(r'[\\/]')).last,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _ParamChip(label: 'ctx ${provider!.contextSize}'),
                    _ParamChip(
                      label: 'T ${provider!.temperature.toStringAsFixed(2)}',
                    ),
                    _ParamChip(label: 'gpu ${provider!.gpuLayers}'),
                    _ParamChip(label: 'max ${provider!.maxTokens}'),
                    _ParamChip(
                      label:
                          'kv ${provider!.cacheTypeK}/${provider!.cacheTypeV}',
                    ),
                    _ParamChip(label: 'batch ${provider!.batchSize}'),
                    _ParamChip(
                      label:
                          provider!.thinkingBudgetTokens == null ||
                              provider!.thinkingBudgetTokens! <= 0
                          ? l10n.localProviderChipThinkNoCap
                          : '${l10n.localProviderChipThink} '
                                '${provider!.thinkingBudgetChipLabel}',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: isActive ? null : onSetActive,
                      icon: const Icon(Icons.check_circle_outline, size: 16),
                      label: Text(l10n.localProviderSetAsDefault),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 32),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSwitcher extends StatelessWidget {
  const _ModeSwitcher({
    required this.useLocal,
    required this.onChanged,
    required this.l10n,
  });

  final bool useLocal;
  final ValueChanged<bool> onChanged;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.appBorder, width: 0.6),
      ),
      child: Row(
        children: [
          Icon(
            useLocal ? Icons.memory : Icons.cloud_outlined,
            size: 18,
            color: AppTheme.primary,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.providerUseLocalModel,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Switch(value: useLocal, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.isActive,
    required this.l10n,
    required this.onTap,
    required this.onToggle,
    required this.onSetActive,
    required this.onTest,
    required this.onFetch,
    required this.onDelete,
  });

  final ModelProvider provider;
  final bool isActive;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSetActive;
  final VoidCallback onTest;
  final VoidCallback onFetch;
  final VoidCallback onDelete;

  String _protocolLabel(BuildContext context) {
    switch (provider.protocol.name) {
      case 'openai':
        return l10n.providerProtocolOpenAI;
      case 'anthropic':
        return l10n.providerProtocolAnthropic;
    }
    return provider.protocol.name;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? AppTheme.primary : context.appBorder,
              width: isActive ? 1.4 : 0.6,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.cloud_outlined,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                provider.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  l10n.commonInUse,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_protocolLabel(context)} · ${l10n.providerModelCount(provider.models.length)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(value: provider.enabled, onChanged: onToggle),
                ],
              ),
              SizedBox(height: 8),
              Text(
                provider.baseUrl,
                style: TextStyle(fontSize: 11, color: context.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (provider.models.isNotEmpty) ...[
                SizedBox(height: 10),
                Text(
                  l10n.providerCurrentModel(
                    provider.selectedModel ?? provider.models.first,
                  ),
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                ),
              ],
              SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      alignment: WrapAlignment.start,
                      children: [
                        TextButton.icon(
                          onPressed: onSetActive,
                          icon: const Icon(Icons.check_circle_outline, size: 16),
                          label: Text(l10n.providerSetAsDefault),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 32),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: onTest,
                          icon: const Icon(Icons.wifi_tethering, size: 16),
                          label: Text(l10n.providerTest),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 32),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: onFetch,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: Text(l10n.providerFetchModels),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: const Size(0, 32),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalProviderCard extends StatelessWidget {
  const _LocalProviderCard({
    required this.provider,
    required this.isActive,
    required this.l10n,
    required this.onTap,
    required this.onToggle,
    required this.onSetActive,
    required this.onDelete,
  });

  final LocalProvider provider;
  final bool isActive;
  final AppLocalizations l10n;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSetActive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? AppTheme.primary : context.appBorder,
              width: isActive ? 1.4 : 0.6,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.memory,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                provider.name,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  l10n.commonInUse,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          provider.displayModelName,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Switch(value: provider.enabled, onChanged: onToggle),
                ],
              ),
              if (provider.mmprojPath != null &&
                  provider.mmprojPath!.isNotEmpty) ...[
                SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.image_outlined,
                      size: 14,
                      color: context.textSecondary,
                    ),
                    SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        provider.mmprojPath!.split(RegExp(r'[\\/]')).last,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _ParamChip(label: 'ctx ${provider.contextSize}'),
                  _ParamChip(
                    label: 'T ${provider.temperature.toStringAsFixed(2)}',
                  ),
                  _ParamChip(label: 'gpu ${provider.gpuLayers}'),
                  _ParamChip(label: 'max ${provider.maxTokens}'),
                  _ParamChip(
                    label: 'kv ${provider.cacheTypeK}/${provider.cacheTypeV}',
                  ),
                  _ParamChip(label: 'batch ${provider.batchSize}'),
                  _ParamChip(
                    label:
                        provider.thinkingBudgetTokens == null ||
                            provider.thinkingBudgetTokens! <= 0
                        ? l10n.localProviderChipThinkNoCap
                        : '${l10n.localProviderChipThink} '
                              '${provider.thinkingBudgetChipLabel}',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: onSetActive,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: Text(l10n.localProviderSetAsDefault),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.redAccent,
                    ),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParamChip extends StatelessWidget {
  const _ParamChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}
