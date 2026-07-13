import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
import '../models/mcp_provider.dart';
import '../services/mcp_service.dart';
import '../theme/app_theme.dart';

class AddMcpProviderPage extends StatefulWidget {
  const AddMcpProviderPage({super.key, this.existing});
  final McpProvider? existing;

  @override
  State<AddMcpProviderPage> createState() => _AddMcpProviderPageState();
}

class _AddMcpProviderPageState extends State<AddMcpProviderPage> {
  late TextEditingController _name;
  late TextEditingController _jsonConfig;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _jsonConfig = TextEditingController(text: widget.existing?.jsonConfig ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _jsonConfig.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mcpNameRequired)),
      );
      return;
    }
    if (_jsonConfig.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mcpJsonConfigRequired)),
      );
      return;
    }

    final provider = McpProvider(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: _name.text.trim(),
      jsonConfig: _jsonConfig.text.trim(),
      enabled: widget.existing?.enabled ?? true,
      createdAt: widget.existing?.createdAt,
    );
    Navigator.of(context).pop(provider);
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context);
    final raw = _jsonConfig.text.trim();
    if (raw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.mcpJsonConfigRequired)),
      );
      return;
    }

    setState(() => _testing = true);
    try {
      final provider = McpProvider(
        id: '',
        name: _name.text.trim().isEmpty ? 'test' : _name.text.trim(),
        jsonConfig: raw,
      );
      final mcp = McpService();
      try {
        await mcp.discoverTools(provider);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.mcpTestSuccess),
            backgroundColor: Colors.green,
          ),
        );
      } finally {
        mcp.dispose();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${l10n.mcpTestFailed}: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.existing == null ? l10n.mcpAddTitle : l10n.mcpEditTitle,
        ),
        actions: [
          TextButton(onPressed: _save, child: Text(l10n.commonSave)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _FieldLabel(text: l10n.mcpName),
          TextField(
            controller: _name,
            decoration: InputDecoration(hintText: l10n.mcpNameHint),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _FieldLabel(text: l10n.mcpJsonConfig),
              ),
              TextButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find, size: 16),
                label: Text(
                  _testing ? l10n.mcpTesting : l10n.mcpTestConnection,
                  style: const TextStyle(fontSize: 12),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AppTheme.primary,
                ),
              ),
            ],
          ),
          TextField(
            controller: _jsonConfig,
            maxLines: 10,
            minLines: 4,
            decoration: InputDecoration(
              hintText: l10n.mcpJsonConfigHint,
              alignLabelWithHint: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
