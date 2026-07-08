import 'package:flutter/material.dart';

import '../models/provider.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

class AddProviderPage extends StatefulWidget {
  const AddProviderPage({super.key, required this.settings, this.existing});

  final SettingsProvider settings;
  final ModelProvider? existing;

  @override
  State<AddProviderPage> createState() => _AddProviderPageState();
}

class _AddProviderPageState extends State<AddProviderPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _name;
  late TextEditingController _baseUrl;
  late TextEditingController _apiKey;
  late ProviderProtocol _protocol;
  late TextEditingController _chatPath;
  bool _obscure = true;
  bool _busy = false;
  List<String> _models = [];
  String? _selectedModel;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _name = TextEditingController(text: p?.name ?? '');
    _protocol = p?.protocol ?? ProviderProtocol.openai;
    _baseUrl = TextEditingController(text: p?.baseUrl ?? _protocol.defaultBaseUrl);
    _apiKey = TextEditingController(text: p?.apiKey ?? '');
    _chatPath = TextEditingController(text: p?.chatPath ?? _protocol.defaultPath);
    _models = List.from(p?.models ?? const []);
    _selectedModel = p?.selectedModel;
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _chatPath.dispose();
    super.dispose();
  }

  void _onProtocolChange(ProviderProtocol? v) {
    if (v == null || v == _protocol) return;
    setState(() {
      _protocol = v;
      if (_baseUrl.text.trim() == _protocol.defaultBaseUrl ||
          _baseUrl.text.trim() == ProviderProtocol.openai.defaultBaseUrl ||
          _baseUrl.text.trim() == ProviderProtocol.anthropic.defaultBaseUrl) {
        _baseUrl.text = v.defaultBaseUrl;
      }
      _chatPath.text = v.defaultPath;
    });
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final api = ApiService();
    final tmp = ModelProvider(
      id: 'tmp',
      name: _name.text.trim(),
      protocol: _protocol,
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      chatPath: _chatPath.text.trim(),
    );
    final ok = await api.testConnection(tmp);
    api.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '✅ 连接成功' : '❌ 连接失败'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _fetchModels() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final api = ApiService();
    final tmp = ModelProvider(
      id: 'tmp',
      name: _name.text.trim(),
      protocol: _protocol,
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      chatPath: _chatPath.text.trim(),
    );
    try {
      final models = await api.fetchModels(tmp);
      if (!mounted) return;
      setState(() {
        _models = models;
        if (_selectedModel == null || !models.contains(_selectedModel)) {
          _selectedModel = models.isNotEmpty ? models.first : null;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ 获取到 ${models.length} 个模型'),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('❌ 获取失败: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      api.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final name = _name.text.trim();
    final baseUrl = _baseUrl.text.trim();
    final apiKey = _apiKey.text.trim();
    final chatPath = _chatPath.text.trim();
    final existing = widget.existing;
    if (existing == null) {
      final provider = await widget.settings.addProvider(
        name: name,
        protocol: _protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        chatPath: chatPath,
      );
      await widget.settings.updateProvider(
        provider.copyWith(
          models: _models,
          selectedModel: _selectedModel,
        ),
      );
    } else {
      final updated = existing.copyWith(
        name: name,
        protocol: _protocol,
        baseUrl: baseUrl,
        apiKey: apiKey,
        chatPath: chatPath,
        models: _models,
        selectedModel: _selectedModel,
      );
      await widget.settings.updateProvider(updated);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '新增提供商' : '编辑提供商'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            const _Label('协议'),
            SegmentedButton<ProviderProtocol>(
              segments: const [
                ButtonSegment(
                  value: ProviderProtocol.openai,
                  label: Text('OpenAI'),
                  icon: Icon(Icons.api, size: 16),
                ),
                ButtonSegment(
                  value: ProviderProtocol.anthropic,
                  label: Text('Anthropic'),
                  icon: Icon(Icons.psychology_alt, size: 16),
                ),
              ],
              selected: {_protocol},
              onSelectionChanged: (s) => _onProtocolChange(s.first),
            ),
            const SizedBox(height: 16),
            const _Label('名称'),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(hintText: '例如: OpenAI 官方'),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请输入名称' : null,
            ),
            const SizedBox(height: 14),
            const _Label('Base URL'),
            TextFormField(
              controller: _baseUrl,
              decoration: const InputDecoration(hintText: 'https://api.openai.com'),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请输入 Base URL' : null,
            ),
            const SizedBox(height: 14),
            const _Label('API Key'),
            TextFormField(
              controller: _apiKey,
              obscureText: _obscure,
              decoration: InputDecoration(
                hintText: 'sk-...',
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility, size: 18),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请输入 API Key' : null,
            ),
            const SizedBox(height: 14),
            const _Label('Chat Path'),
            TextFormField(
              controller: _chatPath,
              decoration: InputDecoration(
                hintText: _protocol.defaultPath,
                helperText: '已根据协议自动补全,通常无需修改',
                helperStyle: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? '请输入 Chat Path' : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _test,
                    icon: const Icon(Icons.wifi_tethering, size: 16),
                    label: const Text('测试连接'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _fetchModels,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('获取模型'),
                  ),
                ),
              ],
            ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 18),
              const _Label('选择默认模型'),
              RadioGroup<String>(
                groupValue: _selectedModel,
                onChanged: (v) => setState(() => _selectedModel = v),
                child: Column(
                  children: _models.map((m) {
                    return RadioListTile<String>(
                      value: m,
                      title: Text(m, style: const TextStyle(fontSize: 13)),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    );
                  }).toList(),
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              height: 46,
              child: ElevatedButton(
                onPressed: _busy ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
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
