import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/local_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'add_local_provider_page.dart';
import 'settings_page.dart';

class LocalProvidersTab extends StatelessWidget {
  const LocalProvidersTab({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final SettingsProvider settings;
  final VoidCallback onChanged;

  Future<void> _openAdd(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddLocalProviderPage(settings: settings),
      ),
    );
    onChanged();
  }

  Future<void> _openEdit(BuildContext context, LocalProvider p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddLocalProviderPage(settings: settings, existing: p),
      ),
    );
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final providers = settings.localProviders;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAdd(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: providers.isEmpty
          ? EmptyHint(
              text: l10n.localProviderListEmpty,
              icon: Icons.memory_outlined,
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: providers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final p = providers[index];
                return _LocalProviderCard(
                  provider: p,
                  isActive: settings.activeLocalProviderId == p.id,
                  l10n: l10n,
                  onTap: () => _openEdit(context, p),
                  onToggle: (v) => settings.toggleLocalProvider(p.id, v),
                  onSetActive: () => settings.setActiveLocalProvider(p.id),
                  onDelete: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: Text(l10n.localProviderDeleteTitle),
                        content: Text(l10n.localProviderDeleteConfirm(p.name)),
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
                      await settings.deleteLocalProvider(p.id);
                      onChanged();
                    }
                  },
                );
              },
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
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isActive ? AppTheme.primary : AppTheme.border,
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
                    child: const Icon(
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
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.image_outlined,
                      size: 14,
                      color: AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        provider.mmprojPath!.split(RegExp(r'[\\/]')).last,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textSecondary,
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
