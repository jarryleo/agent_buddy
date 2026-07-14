import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/google_sheets_service.dart';
import '../theme/app_theme.dart';

/// Bottom sheet that walks the user through Google Sheet setup:
///   1. Paste the spreadsheet URL or ID.
///   2. Click "测试连接" to launch the OAuth browser flow.
///   3. Pick a default tab from the dropdown (refresh first if
///      the sheet was edited in another tab).
///   4. Save.
///
/// Mirrors the visual style of [ReminderCalendarPickerSheet] in
/// `tools_tab.dart` so the two setup flows feel consistent.
class GoogleSheetSettingsSheet extends StatefulWidget {
  const GoogleSheetSettingsSheet({super.key, required this.service});
  final GoogleSheetsService service;

  static Future<void> show(BuildContext context, GoogleSheetsService service) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GoogleSheetSettingsSheet(service: service),
    );
  }

  @override
  State<GoogleSheetSettingsSheet> createState() =>
      _GoogleSheetSettingsSheetState();
}

class _GoogleSheetSettingsSheetState extends State<GoogleSheetSettingsSheet> {
  final _textController = TextEditingController();
  String? _defaultTab;
  bool _busy = false;
  String? _hint;

  @override
  void initState() {
    super.initState();
    final cfg = widget.service.config;
    _textController.text = cfg.hasSpreadsheet ? cfg.spreadsheetId : '';
    _defaultTab = cfg.defaultTab.isEmpty ? null : cfg.defaultTab;
    // Refresh the tab list if we're already authorized and have a
    // sheet — the user might have come back to tweak the default
    // tab, and the sheet may have been edited in another tab.
    if (widget.service.state == GoogleSheetAuthState.authorized) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _refreshTabs();
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  String? get _spreadsheetId {
    final raw = _textController.text.trim();
    if (raw.isEmpty) return null;
    return _extractSpreadsheetId(raw);
  }

  Future<void> _onTestConnection() async {
    final id = _spreadsheetId;
    if (id == null) {
      setState(() => _hint = '请先填写 Google Sheet 链接或 ID');
      return;
    }
    setState(() {
      _busy = true;
      _hint = null;
    });
    final svc = widget.service;
    try {
      // Persist the new id first so the auth flow can find it.
      if (svc.config.spreadsheetId != id) {
        await svc.updateSelection(
          spreadsheetId: id,
          defaultTab: svc.config.defaultTab,
        );
      }
      await svc.startAuthorization();
      if (!mounted) return;
      await _refreshTabs();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _hint = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _hint = '授权失败:${svc.stateError ?? e.toString()}';
      });
    }
  }

  Future<void> _refreshTabs() async {
    final svc = widget.service;
    if (svc.state != GoogleSheetAuthState.authorized) return;
    setState(() => _busy = true);
    try {
      final tabs = await svc.listTabs();
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (tabs.isNotEmpty &&
            (_defaultTab == null || !tabs.contains(_defaultTab))) {
          _defaultTab = tabs.first;
        }
        _hint = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _hint = '读取表格失败:${e.toString()}';
      });
    }
  }

  Future<void> _onSave() async {
    final id = _spreadsheetId;
    if (id == null) {
      setState(() => _hint = '请先填写 Google Sheet 链接或 ID');
      return;
    }
    if (widget.service.state != GoogleSheetAuthState.authorized) {
      setState(() => _hint = '请先点击"测试连接"完成授权');
      return;
    }
    final tab = _defaultTab ?? '';
    await widget.service.updateSelection(spreadsheetId: id, defaultTab: tab);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _onSignOut() async {
    await widget.service.signOut();
    if (!mounted) return;
    setState(() {
      _defaultTab = null;
      _hint = '已退出登录,可重新授权。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final svc = widget.service;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) {
        return Container(
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              _Grabber(),
              const SizedBox(height: 8),
              Text(
                l10n.googleSheetSheetTitle,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.googleSheetSheetSubtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: context.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.googleSheetInputLabel,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _textController,
                enabled: !_busy,
                decoration: InputDecoration(
                  hintText: l10n.googleSheetInputHint,
                  errorText: _hint != null && _hint!.contains('Google Sheet')
                      ? _hint
                      : null,
                ),
                onChanged: (_) {
                  if (_hint != null) setState(() => _hint = null);
                },
                onSubmitted: (_) => _onTestConnection(),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _onTestConnection,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login, size: 18),
                  label: Text(
                    svc.state == GoogleSheetAuthState.authorizing
                        ? l10n.googleSheetTestAuthorizing
                        : l10n.googleSheetTestButton,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _AuthStatusCard(service: svc),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.googleSheetDefaultTabLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed:
                        _busy || svc.state != GoogleSheetAuthState.authorized
                        ? null
                        : _refreshTabs,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.googleSheetRefreshButton),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _TabDropdown(
                tabs: svc.availableTabs,
                value: _defaultTab,
                enabled: !_busy && svc.state == GoogleSheetAuthState.authorized,
                emptyHint: svc.state == GoogleSheetAuthState.authorized
                    ? l10n.googleSheetEmptyTabs
                    : l10n.googleSheetEmptyTabsUnauthorized,
                onChanged: (v) => setState(() => _defaultTab = v),
              ),
              if (_hint != null && !_hint!.contains('Google Sheet')) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: context.textSecondary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _hint!,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Row(
                children: [
                  if (svc.state == GoogleSheetAuthState.authorized)
                    TextButton(
                      onPressed: _busy ? null : _onSignOut,
                      child: Text(
                        l10n.googleSheetSignOut,
                        style: TextStyle(color: context.textSecondary),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: Text(l10n.commonCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : _onSave,
                    child: Text(l10n.commonSave),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Grabber extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: context.appBorder,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _AuthStatusCard extends StatelessWidget {
  const _AuthStatusCard({required this.service});
  final GoogleSheetsService service;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cfg = service.config;
    final state = service.state;
    final (label, icon, color) = switch (state) {
      GoogleSheetAuthState.unconfigured => (
        l10n.googleSheetStatusUnconfigured,
        Icons.link_off,
        context.textSecondary,
      ),
      GoogleSheetAuthState.unauthorized => (
        l10n.googleSheetStatusUnauthorized,
        Icons.error_outline,
        AppTheme.primary,
      ),
      GoogleSheetAuthState.authorizing => (
        l10n.googleSheetStatusAuthorizing,
        Icons.hourglass_top,
        context.textSecondary,
      ),
      GoogleSheetAuthState.authorized => (
        cfg.authedEmail == null || cfg.authedEmail!.isEmpty
            ? l10n.googleSheetStatusAuthorized
            : l10n.googleSheetStatusAuthorizedAs(cfg.authedEmail!),
        Icons.check_circle,
        Colors.green,
      ),
      GoogleSheetAuthState.error => (
        l10n.googleSheetStatusError,
        Icons.error,
        Colors.red,
      ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (service.stateError != null &&
                    state == GoogleSheetAuthState.error) ...[
                  const SizedBox(height: 2),
                  Text(
                    service.stateError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabDropdown extends StatelessWidget {
  const _TabDropdown({
    required this.tabs,
    required this.value,
    required this.enabled,
    required this.emptyHint,
    required this.onChanged,
  });
  final List<String> tabs;
  final String? value;
  final bool enabled;
  final String emptyHint;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: context.appBorder.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          emptyHint,
          style: TextStyle(fontSize: 13, color: context.textSecondary),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: context.appBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: value != null && tabs.contains(value) ? value : null,
          hint: Text(tabs.first, style: const TextStyle(fontSize: 14)),
          items: [
            for (final t in tabs) DropdownMenuItem(value: t, child: Text(t)),
          ],
          onChanged: enabled ? onChanged : null,
        ),
      ),
    );
  }
}

/// Spreadsheet ID extractor. Accepts the bare ID, the canonical
/// `/spreadsheets/d/<id>/edit` URL, and the `/d/e/2PACX-...`
/// "published-as-html" URL (the latter is uncommon but the regex
/// pattern is forgiving).
String _extractSpreadsheetId(String input) {
  final s = input.trim();
  final match = RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)').firstMatch(s);
  if (match != null) return match.group(1)!;
  if (RegExp(r'^[a-zA-Z0-9-_]{20,}$').hasMatch(s)) return s;
  return s;
}
