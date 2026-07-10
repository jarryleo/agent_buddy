import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import 'code_block.dart';
import 'image_preview.dart';

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({super.key, required this.data, this.onCopy});

  final String data;
  final ValueChanged<String>? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = MarkdownStyleSheet(
      p: TextStyle(fontSize: 15, height: 1.6, color: context.textPrimary),
      h1: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: context.textPrimary,
      ),
      h2: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: context.textPrimary,
      ),
      h3: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: context.textPrimary,
      ),
      h4: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: context.textPrimary,
      ),
      h5: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: context.textPrimary,
      ),
      h6: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        height: 1.3,
        color: context.textPrimary,
      ),
      strong: TextStyle(
        fontWeight: FontWeight.w700,
        color: context.textPrimary,
      ),
      em: TextStyle(fontStyle: FontStyle.italic, color: context.textPrimary),
      del: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: context.textSecondary,
      ),
      a: TextStyle(
        color: AppTheme.primary,
        decoration: TextDecoration.underline,
        decorationColor: AppTheme.primary,
      ),
      blockquote: TextStyle(
        color: context.textSecondary,
        fontSize: 14,
        height: 1.5,
        fontStyle: FontStyle.italic,
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      blockquoteDecoration: BoxDecoration(
        color: context.bg,
        border: Border(left: BorderSide(color: AppTheme.primary, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      code: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: Color(0xFFB91C1C),
        backgroundColor: Color(0xFFF6F8FA),
      ),
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      listBullet: TextStyle(fontSize: 15, color: context.textPrimary),
      listIndent: 20,
      tableHead: TextStyle(
        fontWeight: FontWeight.w600,
        color: context.textPrimary,
      ),
      tableBody: TextStyle(color: context.textPrimary),
      tableBorder: TableBorder.all(color: context.appBorder, width: 0.5),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      tableHeadAlign: TextAlign.left,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.appBorder, width: 0.6)),
      ),
    );

    final styleSheet = base.copyWith(
      p: base.p?.merge(theme.textTheme.bodyMedium ?? TextStyle()),
    );

    return MarkdownBody(
      data: data,
      selectable: true,
      shrinkWrap: true,
      styleSheet: styleSheet,
      onTapLink: (text, href, title) async {
        if (href == null || href.isEmpty) return;
        final uri = Uri.tryParse(href);
        if (uri == null) return;
        if (uri.scheme == 'http' || uri.scheme == 'https') {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      imageBuilder: (uri, title, alt) {
        final isNetwork = uri.scheme == 'http' || uri.scheme == 'https';
        final image = isNetwork
            ? Image.network(
                uri.toString(),
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) {
                  if (progress == null) return child;
                  return Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.expectedTotalBytes != null
                            ? progress.cumulativeBytesLoaded /
                                  (progress.expectedTotalBytes ?? 1)
                            : null,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stack) => Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: context.appBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.broken_image_outlined,
                        size: 18,
                        color: context.textSecondary,
                      ),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          alt ?? uri.toString(),
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Image.asset(uri.toString(), fit: BoxFit.contain);
        return GestureDetector(
          onTap: isNetwork
              ? () => ImagePreviewPage.showNetwork(
                  context,
                  uri.toString(),
                  title: title,
                )
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxHeight: 320,
                maxWidth: double.infinity,
              ),
              child: image,
            ),
          ),
        );
      },
      builders: {'pre': _CodeBlockBuilder()},
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final raw = element.textContent;
    final language = (element.attributes['class'] ?? '')
        .split(' ')
        .firstWhere((c) => c.startsWith('language-'), orElse: () => '')
        .replaceFirst('language-', '');
    return CodeBlock(code: raw, language: language);
  }
}
