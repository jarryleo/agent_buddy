import 'package:flutter/material.dart';

import '../models/role.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class RolesTab extends StatelessWidget {
  const RolesTab({super.key, required this.settings});
  final SettingsProvider settings;

  Future<void> _openEdit(BuildContext context, [Role? role]) async {
    final result = await Navigator.of(context).push<Role?>(
      MaterialPageRoute(builder: (_) => _RoleEditPage(initial: role)),
    );
    if (result == null) return;
    if (role == null) {
      await settings.addRole(
        name: result.name,
        avatar: result.avatar,
        description: result.description,
        systemPrompt: result.systemPrompt,
      );
    } else {
      await settings.updateRole(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roles = settings.roles;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context),
        icon: const Icon(Icons.add),
        label: const Text('新增'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: roles.isEmpty
          ? const EmptyHint(
              text: '还没有添加任何角色\n点击右下角"新增"创建你的第一个角色',
              icon: Icons.person_outline,
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: roles.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final r = roles[index];
                final active = settings.activeRoleId == r.id;
                return Material(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openEdit(context, r),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: active ? AppTheme.primary : AppTheme.border,
                          width: active ? 1.4 : 0.6,
                        ),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                            child: Text(
                              r.name.isNotEmpty ? r.name.characters.first : '?',
                              style: const TextStyle(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        r.name,
                                        style: const TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (active)
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
                                if (r.description.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    r.description,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    TextButton(
                                      onPressed: () => settings.setActiveRole(active ? null : r.id),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(horizontal: 6),
                                        minimumSize: const Size(0, 28),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: Text(active ? '取消使用' : '使用此角色'),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('删除角色'),
                                            content: Text('确认删除 "${r.name}"?'),
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
                                          await settings.deleteRole(r.id);
                                        }
                                      },
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18, color: Colors.redAccent),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _RoleEditPage extends StatefulWidget {
  const _RoleEditPage({this.initial});
  final Role? initial;

  @override
  State<_RoleEditPage> createState() => _RoleEditPageState();
}

class _RoleEditPageState extends State<_RoleEditPage> {
  late TextEditingController _name;
  late TextEditingController _description;
  late TextEditingController _systemPrompt;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _description = TextEditingController(text: widget.initial?.description ?? '');
    _systemPrompt = TextEditingController(text: widget.initial?.systemPrompt ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入角色名称')),
      );
      return;
    }
    final role = Role(
      id: widget.initial?.id ?? '',
      name: _name.text.trim(),
      description: _description.text.trim(),
      systemPrompt: _systemPrompt.text,
      enabled: widget.initial?.enabled ?? true,
    );
    Navigator.of(context).pop(role);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '新增角色' : '编辑角色'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _FieldLabel('名称'),
          TextField(controller: _name, decoration: const InputDecoration(hintText: '例如: 翻译助手')),
          const SizedBox(height: 14),
          const _FieldLabel('简介'),
          TextField(
            controller: _description,
            maxLines: 2,
            decoration: const InputDecoration(hintText: '一句话描述这个角色的作用'),
          ),
          const SizedBox(height: 14),
          const _FieldLabel('系统提示词 (System Prompt)'),
          TextField(
            controller: _systemPrompt,
            maxLines: 10,
            minLines: 5,
            decoration: const InputDecoration(
              hintText: '描述角色的身份、行为、风格、规则等',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}
