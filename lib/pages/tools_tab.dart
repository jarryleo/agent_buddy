import 'package:flutter/material.dart';

import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class ToolsTab extends StatelessWidget {
  const ToolsTab({super.key, required this.settings});
  final SettingsProvider settings;

  @override
  Widget build(BuildContext context) {
    final tools = settings.tools;
    if (tools.isEmpty) {
      return const EmptyHint(
        text: '暂无内置工具',
        icon: Icons.handyman_outlined,
      );
    }
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: tools.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final t = tools[index];
          final active = settings.activeToolIds.contains(t.id);
          return Material(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active ? AppTheme.primary : AppTheme.border,
                  width: active ? 1.4 : 0.6,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.handyman_outlined,
                        color: AppTheme.primary, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.description,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: t.enabled,
                    onChanged: (v) => settings.toggleTool(t.id, v),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
