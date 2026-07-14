import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/skill.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class SkillsTab extends StatelessWidget {
  const SkillsTab({super.key, required this.settings});
  final SettingsProvider settings;

  Future<void> _openEdit(BuildContext context, [Skill? skill]) async {
    final result = await Navigator.of(context).push<Skill?>(
      MaterialPageRoute(builder: (_) => _SkillEditPage(initial: skill)),
    );
    if (result == null) return;
    if (skill == null) {
      await settings.addSkill(
        name: result.name,
        description: result.description,
        content: result.content,
      );
    } else {
      await settings.updateSkill(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final skills = settings.skills;
    return Scaffold(
      backgroundColor: context.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context),
        icon: Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: skills.isEmpty
          ? EmptyHint(
              text: l10n.skillListEmpty,
              icon: Icons.workspace_premium_outlined,
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: skills.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final s = skills[index];
                final active = settings.activeSkillIds.contains(s.id);
                return Material(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openEdit(context, s),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: active ? AppTheme.primary : context.appBorder,
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
                            child: Icon(
                              Icons.workspace_premium_outlined,
                              color: AppTheme.primary,
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (s.description.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    s.description,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: context.textSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Switch(
                            value: s.enabled,
                            onChanged: (v) => settings.toggleSkill(s.id, v),
                          ),
                          if (!s.isBuiltin)
                            IconButton(
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: Text(l10n.skillDeleteTitle),
                                    content: Text(
                                      l10n.skillDeleteConfirm(s.name),
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
                                  await settings.deleteSkill(s.id);
                                }
                              },
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              visualDensity: VisualDensity.compact,
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

class _SkillEditPage extends StatefulWidget {
  const _SkillEditPage({this.initial});
  final Skill? initial;

  @override
  State<_SkillEditPage> createState() => _SkillEditPageState();
}

class _SkillEditPageState extends State<_SkillEditPage> {
  late TextEditingController _name;
  late TextEditingController _description;
  late TextEditingController _content;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _description = TextEditingController(
      text: widget.initial?.description ?? '',
    );
    _content = TextEditingController(text: widget.initial?.content ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.skillNameRequired)));
      return;
    }
    final skill = Skill(
      id: widget.initial?.id ?? '',
      name: _name.text.trim(),
      description: _description.text.trim(),
      content: _content.text,
      enabled: widget.initial?.enabled ?? true,
    );
    Navigator.of(context).pop(skill);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initial == null ? l10n.skillAddTitle : l10n.skillEditTitle,
        ),
        actions: [TextButton(onPressed: _save, child: Text(l10n.commonSave))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _FieldLabel(text: l10n.skillName),
          TextField(
            controller: _name,
            decoration: InputDecoration(hintText: l10n.skillNameHint),
          ),
          const SizedBox(height: 14),
          _FieldLabel(text: l10n.skillDescription),
          TextField(
            controller: _description,
            maxLines: 2,
            decoration: InputDecoration(hintText: l10n.skillDescriptionHint),
          ),
          const SizedBox(height: 14),
          _FieldLabel(text: l10n.skillContent),
          TextField(
            controller: _content,
            maxLines: 14,
            minLines: 6,
            decoration: InputDecoration(
              hintText: l10n.skillContentHint,
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
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.textSecondary,
        ),
      ),
    );
  }
}
