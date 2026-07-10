import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/github.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

class CodeBlock extends StatefulWidget {
  const CodeBlock({super.key, required this.code, required this.language});

  final String code;
  final String language;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _copied = false;

  static const _supportedLanguages = <String>{
    'dart',
    'javascript',
    'typescript',
    'jsx',
    'tsx',
    'python',
    'java',
    'kotlin',
    'swift',
    'objectivec',
    'go',
    'rust',
    'c',
    'cpp',
    'csharp',
    'ruby',
    'php',
    'scala',
    'r',
    'lua',
    'sql',
    'json',
    'yaml',
    'xml',
    'html',
    'css',
    'scss',
    'less',
    'shell',
    'bash',
    'sh',
    'powershell',
    'markdown',
    'diff',
    'dockerfile',
    'nginx',
    'makefile',
    'cmake',
    'ini',
    'toml',
    'plaintext',
  };

  String _resolveLanguage() {
    final lang = widget.language.toLowerCase().trim();
    if (lang.isEmpty) return 'plaintext';
    if (_supportedLanguages.contains(lang)) return lang;
    final aliases = <String, String>{
      'js': 'javascript',
      'ts': 'typescript',
      'py': 'python',
      'rb': 'ruby',
      'cs': 'csharp',
      'c++': 'cpp',
      'objc': 'objectivec',
      'objective-c': 'objectivec',
      'yml': 'yaml',
      'md': 'markdown',
      'shellscript': 'bash',
      'zsh': 'bash',
      'vue': 'xml',
      'pgsql': 'sql',
      'mysql': 'sql',
    };
    return aliases[lang] ?? 'plaintext';
  }

  String _displayLanguage(String lang) {
    if (widget.language.isNotEmpty) return widget.language.toLowerCase();
    if (lang == 'plaintext') return 'text';
    return lang;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lang = _resolveLanguage();
    final codeText = widget.code.endsWith('\n')
        ? widget.code.substring(0, widget.code.length - 1)
        : widget.code;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1117),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF161B22),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
              border: Border(bottom: BorderSide(color: Color(0xFF30363D))),
            ),
            child: Row(
              children: [
                Text(
                  _displayLanguage(lang),
                  style: const TextStyle(
                    color: Color(0xFF8B949E),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: _copy,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _copied ? Icons.check_rounded : Icons.copy_rounded,
                          size: 12,
                          color: _copied
                              ? const Color(0xFF3FB950)
                              : const Color(0xFF8B949E),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _copied ? l10n.codeCopied : l10n.codeCopy,
                          style: TextStyle(
                            color: _copied
                                ? const Color(0xFF3FB950)
                                : const Color(0xFF8B949E),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: HighlightView(
              codeText,
              language: lang,
              theme: githubTheme,
              padding: EdgeInsets.zero,
              textStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.5,
                color: context.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
