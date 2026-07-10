import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/memory.dart';
import '../providers/memory_provider.dart';
import '../theme/app_theme.dart';
import 'settings_page.dart';

class MemoryTab extends StatefulWidget {
  const MemoryTab({super.key});

  @override
  State<MemoryTab> createState() => _MemoryTabState();
}

class _MemoryTabState extends State<MemoryTab> {
  final TextEditingController _search = TextEditingController();
  String _keyword = '';
  final Set<String> _selected = {};
  bool _multiSelect = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(() {
      final k = _search.text.trim();
      if (k == _keyword) return;
      setState(() => _keyword = k);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _enterMultiSelect([String? firstId]) {
    setState(() {
      _multiSelect = true;
      _selected
        ..clear()
        ..addAll(firstId == null ? const [] : [firstId]);
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _selected.clear();
    });
  }

  Future<void> _openEdit(BuildContext context, [Memory? memory]) async {
    final l10n = AppLocalizations.of(context);
    final provider = context.read<MemoryProvider>();
    final result = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => _MemoryEditPage(
          initial: memory,
          title: memory == null ? l10n.memoryAddTitle : l10n.memoryEditTitle,
          contentLabel: l10n.memoryContent,
          contentHint: l10n.memoryContentHint,
          contentRequired: l10n.memoryContentRequired,
          saveLabel: l10n.commonSave,
          cancelLabel: l10n.commonCancel,
        ),
      ),
    );
    if (result == null) return;
    if (memory == null) {
      await provider.addUser(content: result);
    } else {
      await provider.update(id: memory.id, content: result);
    }
  }

  Future<void> _confirmDelete(BuildContext context, Memory m) async {
    final l10n = AppLocalizations.of(context);
    final provider = context.read<MemoryProvider>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoryDeleteTitle),
        content: Text(l10n.memoryDeleteConfirm),
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
      await provider.delete(m.id);
    }
  }

  Future<void> _confirmDeleteBatch(
    BuildContext context,
    List<String> ids,
  ) async {
    final l10n = AppLocalizations.of(context);
    final provider = context.read<MemoryProvider>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.memoryDeleteBatchConfirmTitle(ids.length)),
        content: Text(l10n.memoryDeleteBatchMessage),
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
      await provider.deleteMany(ids);
      _exitMultiSelect();
    }
  }

  String _formatRelative(BuildContext context, DateTime t) {
    final l10n = AppLocalizations.of(context);
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return l10n.memoryJustNow;
    if (diff.inMinutes < 60) return l10n.memoryMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l10n.memoryHoursAgo(diff.inHours);
    if (diff.inDays < 30) return l10n.memoryDaysAgo(diff.inDays);
    final mm = t.month.toString().padLeft(2, '0');
    final dd = t.day.toString().padLeft(2, '0');
    return '${t.year}-$mm-$dd';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final provider = context.watch<MemoryProvider>();
    final memories = provider.list(keyword: _keyword, max: 200);

    if (_multiSelect) {
      return Scaffold(
        backgroundColor: context.bg,
        body: Column(
          children: [
            _MultiSelectBar(
              count: _selected.length,
              total: memories.length,
              onSelectAll: () {
                setState(() {
                  _selected
                    ..clear()
                    ..addAll(memories.map((m) => m.id));
                });
              },
              onClearAll: () {
                setState(() => _selected.clear());
              },
              onDelete: () => _confirmDeleteBatch(context, _selected.toList()),
              onCancel: _exitMultiSelect,
              selectAllLabel: l10n.memorySelectAll,
              deselectAllLabel: l10n.memoryDeselectAll,
              deleteLabel: l10n.commonDelete,
            ),
            Expanded(
              child: _MemoryList(
                memories: memories,
                isMultiSelect: true,
                selected: _selected,
                onTap: (m) {
                  setState(() {
                    if (_selected.contains(m.id)) {
                      _selected.remove(m.id);
                      if (_selected.isEmpty) _exitMultiSelect();
                    } else {
                      _selected.add(m.id);
                    }
                  });
                },
                formatRelative: (t) => _formatRelative(context, t),
                aiLabel: l10n.memorySourceAi,
                userLabel: l10n.memorySourceUser,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.bg,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEdit(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.commonAdd),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          _SearchBar(
            controller: _search,
            hint: l10n.memorySearch,
            clearLabel: l10n.memorySearchClear,
            onClear: () {
              _search.clear();
              setState(() => _keyword = '');
            },
          ),
          Expanded(
            child: memories.isEmpty
                ? EmptyHint(
                    text: _keyword.isEmpty
                        ? l10n.memoryListEmpty
                        : l10n.memorySearchEmpty(_keyword),
                    icon: Icons.psychology_outlined,
                  )
                : _MemoryList(
                    memories: memories,
                    isMultiSelect: false,
                    selected: _selected,
                    onTap: (m) => _openEdit(context, m),
                    onLongPress: (m) => _enterMultiSelect(m.id),
                    formatRelative: (t) => _formatRelative(context, t),
                    aiLabel: l10n.memorySourceAi,
                    userLabel: l10n.memorySourceUser,
                    editLabel: l10n.memoryEdit,
                    deleteLabel: l10n.commonDelete,
                    onEdit: (m) => _openEdit(context, m),
                    onDelete: (m) => _confirmDelete(context, m),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.hint,
    required this.clearLabel,
    required this.onClear,
  });
  final TextEditingController controller;
  final String hint;
  final String clearLabel;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: clearLabel,
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: onClear,
                ),
          filled: true,
          fillColor: context.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: context.appBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: context.appBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppTheme.primary, width: 1.4),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
        ),
      ),
    );
  }
}

class _MultiSelectBar extends StatelessWidget {
  const _MultiSelectBar({
    required this.count,
    required this.total,
    required this.onSelectAll,
    required this.onClearAll,
    required this.onDelete,
    required this.onCancel,
    required this.selectAllLabel,
    required this.deselectAllLabel,
    required this.deleteLabel,
  });
  final int count;
  final int total;
  final VoidCallback onSelectAll;
  final VoidCallback onClearAll;
  final VoidCallback onDelete;
  final VoidCallback onCancel;
  final String selectAllLabel;
  final String deselectAllLabel;
  final String deleteLabel;

  @override
  Widget build(BuildContext context) {
    final allSelected = total > 0 && count == total;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(bottom: BorderSide(color: context.appBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onCancel,
            visualDensity: VisualDensity.compact,
          ),
          Text(
            '$count',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 4),
          Text(
            '/ $total',
            style: TextStyle(fontSize: 13, color: context.textSecondary),
          ),
          const Spacer(),
          TextButton(
            onPressed: allSelected ? onClearAll : onSelectAll,
            child: Text(allSelected ? deselectAllLabel : selectAllLabel),
          ),
          TextButton(
            onPressed: count == 0 ? null : onDelete,
            child: Text(
              deleteLabel,
              style: TextStyle(
                color: count == 0 ? context.textSecondary : Colors.redAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoryList extends StatelessWidget {
  const _MemoryList({
    required this.memories,
    required this.isMultiSelect,
    required this.selected,
    required this.onTap,
    required this.formatRelative,
    required this.aiLabel,
    required this.userLabel,
    this.onLongPress,
    this.editLabel,
    this.deleteLabel,
    this.onEdit,
    this.onDelete,
  });
  final List<Memory> memories;
  final bool isMultiSelect;
  final Set<String> selected;
  final ValueChanged<Memory> onTap;
  final ValueChanged<Memory>? onLongPress;
  final String Function(DateTime) formatRelative;
  final String aiLabel;
  final String userLabel;
  final String? editLabel;
  final String? deleteLabel;
  final ValueChanged<Memory>? onEdit;
  final ValueChanged<Memory>? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
      itemCount: memories.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final m = memories[index];
        final isSelected = selected.contains(m.id);
        return Material(
          color: context.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onTap(m),
            onLongPress: isMultiSelect ? null : () => onLongPress?.call(m),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected ? AppTheme.primary : context.appBorder,
                  width: isSelected ? 1.4 : 0.6,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isMultiSelect)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 8),
                      child: Icon(
                        isSelected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        size: 18,
                        color: isSelected
                            ? AppTheme.primary
                            : context.textSecondary,
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          m.content,
                          style: const TextStyle(fontSize: 14, height: 1.45),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            _SourceChip(
                              source: m.source,
                              aiLabel: aiLabel,
                              userLabel: userLabel,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              formatRelative(m.createdAt),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (!isMultiSelect &&
                      editLabel != null &&
                      deleteLabel != null &&
                      onEdit != null &&
                      onDelete != null)
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_horiz,
                        size: 18,
                        color: context.textSecondary,
                      ),
                      padding: EdgeInsets.zero,
                      splashRadius: 18,
                      onSelected: (v) {
                        if (v == 'edit') onEdit!(m);
                        if (v == 'delete') onDelete!(m);
                      },
                      itemBuilder: (ctx) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Row(
                            children: [
                              const Icon(Icons.edit_outlined, size: 16),
                              const SizedBox(width: 8),
                              Text(editLabel!),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              const Icon(
                                Icons.delete_outline,
                                size: 16,
                                color: Colors.redAccent,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                deleteLabel!,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({
    required this.source,
    required this.aiLabel,
    required this.userLabel,
  });
  final String source;
  final String aiLabel;
  final String userLabel;

  @override
  Widget build(BuildContext context) {
    final isAi = source == 'ai';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (isAi ? AppTheme.primary : Colors.blueGrey).withValues(
          alpha: 0.1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isAi ? aiLabel : userLabel,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: isAi ? AppTheme.primary : Colors.blueGrey,
        ),
      ),
    );
  }
}

class _MemoryEditPage extends StatefulWidget {
  const _MemoryEditPage({
    required this.initial,
    required this.title,
    required this.contentLabel,
    required this.contentHint,
    required this.contentRequired,
    required this.saveLabel,
    required this.cancelLabel,
  });
  final Memory? initial;
  final String title;
  final String contentLabel;
  final String contentHint;
  final String contentRequired;
  final String saveLabel;
  final String cancelLabel;

  @override
  State<_MemoryEditPage> createState() => _MemoryEditPageState();
}

class _MemoryEditPageState extends State<_MemoryEditPage> {
  late final TextEditingController _content;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(text: widget.initial?.content ?? '');
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  void _save() {
    final v = _content.text.trim();
    if (v.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.contentRequired)));
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [TextButton(onPressed: _save, child: Text(widget.saveLabel))],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.contentLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: TextField(
                controller: _content,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: widget.contentHint,
                  filled: true,
                  fillColor: context.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: context.appBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: context.appBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(
                      color: AppTheme.primary,
                      width: 1.4,
                    ),
                  ),
                  contentPadding: const EdgeInsets.all(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
