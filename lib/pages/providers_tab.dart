import 'package:flutter/material.dart';

import '../models/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';
import 'add_provider_page.dart';
import 'settings_page.dart';

class ProvidersTab extends StatelessWidget {
  const ProvidersTab({super.key, required this.settings, required this.onChanged});

  final SettingsProvider settings;
  final VoidCallback onChanged;

  Future<void> _openAdd(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddProviderPage(settings: settings),
      ),
    );
    onChanged();
  }

  Future<void> _openEdit(BuildContext context, ModelProvider p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddProviderPage(settings: settings, existing: p),
      ),
    );
    onChanged();
  }

  Future<void> _testConnection(BuildContext context, ModelProvider p) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Text('正在测试连接…'),
      duration: Duration(seconds: 1),
    ));
    final api = ApiService();
    final ok = await api.testConnection(p);
    api.dispose();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(ok ? '✅ 连接成功' : '❌ 连接失败,请检查 URL/API Key'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _fetchModels(BuildContext context, ModelProvider p) async {
    final messenger = ScaffoldMessenger.of(context);
    final api = ApiService();
    try {
      messenger.showSnackBar(const SnackBar(
        content: Text('正在获取模型列表…'),
        duration: Duration(seconds: 1),
      ));
      final models = await api.fetchModels(p);
      final updated = p.copyWith(models: models);
      await settings.updateProvider(updated);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('✅ 获取到 ${models.length} 个模型'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('❌ 获取失败: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      api.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final providers = settings.providers;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAdd(context),
        icon: const Icon(Icons.add),
        label: const Text('新增'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: providers.isEmpty
          ? const EmptyHint(
              text: '还没有添加任何模型提供商\n点击右下角"新增"开始',
              icon: Icons.cloud_outlined,
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: providers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final p = providers[index];
                return _ProviderCard(
                  provider: p,
                  isActive: settings.activeProviderId == p.id,
                  onTap: () => _openEdit(context, p),
                  onToggle: (v) => settings.toggleProvider(p.id, v),
                  onSetActive: () => settings.setActiveProvider(p.id),
                  onTest: () => _testConnection(context, p),
                  onFetch: () => _fetchModels(context, p),
                  onDelete: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除提供商'),
                        content: Text('确认删除 "${p.name}"?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('删除'),
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
            ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.isActive,
    required this.onTap,
    required this.onToggle,
    required this.onSetActive,
    required this.onTest,
    required this.onFetch,
    required this.onDelete,
  });

  final ModelProvider provider;
  final bool isActive;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onSetActive;
  final VoidCallback onTest;
  final VoidCallback onFetch;
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
                    child: const Icon(Icons.cloud_outlined, color: AppTheme.primary, size: 20),
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
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  '使用中',
                                  style: TextStyle(
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
                          '${provider.protocol.label} · ${provider.models.length} 个模型',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(value: provider.enabled, onChanged: onToggle),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                provider.baseUrl,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (provider.models.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  '当前模型: ${provider.selectedModel ?? provider.models.first}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: onSetActive,
                    icon: const Icon(Icons.check_circle_outline, size: 16),
                    label: const Text('设为默认'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: onTest,
                    icon: const Icon(Icons.wifi_tethering, size: 16),
                    label: const Text('测试'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: onFetch,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('获取模型'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
