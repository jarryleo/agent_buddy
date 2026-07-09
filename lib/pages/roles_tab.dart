import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
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
    final l10n = AppLocalizations.of(context);
    final roles = settings.roles;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: roles.isEmpty
          ? EmptyHint(text: l10n.roleListEmpty, icon: Icons.person_outline)
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
                            backgroundColor: AppTheme.primary.withValues(
                              alpha: 0.12,
                            ),
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
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppTheme.primary,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
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
                                      onPressed: () => settings.setActiveRole(
                                        active ? null : r.id,
                                      ),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        minimumSize: const Size(0, 28),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: Text(
                                        active
                                            ? l10n.roleUnuseRole
                                            : l10n.roleUseRole,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: Text(l10n.roleDeleteTitle),
                                            content: Text(
                                              l10n.roleDeleteConfirm(r.name),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, false),
                                                child: Text(l10n.commonCancel),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                child: Text(l10n.commonDelete),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          await settings.deleteRole(r.id);
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 18,
                                        color: Colors.redAccent,
                                      ),
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
    _description = TextEditingController(
      text: widget.initial?.description ?? '',
    );
    _systemPrompt = TextEditingController(
      text: widget.initial?.systemPrompt ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.roleNameRequired)));
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
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? l10n.roleAddTitle : l10n.roleEditTitle,
        ),
        actions: [TextButton(onPressed: _save, child: Text(l10n.commonSave))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _FieldLabel(text: l10n.roleName),
          TextField(
            controller: _name,
            decoration: InputDecoration(hintText: l10n.roleNameHint),
          ),
          const SizedBox(height: 14),
          _FieldLabel(text: l10n.roleDescription),
          TextField(
            controller: _description,
            maxLines: 2,
            decoration: InputDecoration(hintText: l10n.roleDescriptionHint),
          ),
          const SizedBox(height: 14),
          _FieldLabel(text: l10n.roleSystemPrompt),
          TextField(
            controller: _systemPrompt,
            maxLines: 10,
            minLines: 5,
            decoration: InputDecoration(
              hintText: l10n.roleSystemPromptHint,
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.text});
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
