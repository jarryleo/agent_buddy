import 'dart:convert';
import 'dart:io';

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
    // Decode images at the bubble's actual pixel footprint * dpr instead
    // of full-resolution. Without `cacheWidth`/`cacheHeight` Flutter loads
    // the full photo and then samples it on the GPU, which combined with the
    // default FilterQuality.medium looks visibly soft in a chat bubble.
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final bubbleCacheWidth = (media.size.width * dpr).round();
    final bubbleCacheHeight = (320 * dpr).round();
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
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFFF7B72)
            : const Color(0xFFB91C1C),
        backgroundColor: context.codeBlockBg,
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

    // NOTE: `MarkdownBody(selectable: true)` builds an internal
    // Viewport for the selectable text. When the markdown content is
    // empty / near-empty (e.g. the streaming placeholder that is just
    // a single space, or a message that is pure image/code block) that
    // Viewport has no hit-testable sliver child, and the first pointer
    // event crashes inside `RenderViewportBase.hitTestChildren`
    // (viewport.dart:886) with "Null check operator used on a null
    // value". We disable the built-in selectable and instead wrap the
    // whole body in a `SelectionArea`, which provides text selection
    // without relying on markdown's internal viewport and therefore
    // does not have the empty-content hit-test bug.
    return SelectionArea(
      child: MarkdownBody(
        data: data,
        selectable: false,
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
        final scheme = uri.scheme;
        final isNetwork = scheme == 'http' || scheme == 'https';
        final isFile = scheme == 'file';
        final isData = scheme == 'data';

        Widget image;
        if (isNetwork) {
          image = Image.network(
            uri.toString(),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            cacheWidth: bubbleCacheWidth,
            cacheHeight: bubbleCacheHeight,
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
            errorBuilder: (context, error, stack) =>
                _imageError(context, alt ?? uri.toString()),
          );
        } else if (isFile) {
          final filePath = uri.toFilePath();
          image = Image.file(
            File(filePath),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            cacheWidth: bubbleCacheWidth,
            cacheHeight: bubbleCacheHeight,
            errorBuilder: (context, error, stack) =>
                _imageError(context, alt ?? uri.toString()),
          );
        } else if (isData) {
          image = _buildDataImage(
            context,
            uri,
            alt,
            cacheWidth: bubbleCacheWidth,
            cacheHeight: bubbleCacheHeight,
          );
        } else {
          // Fallback: try as a local file path or relative path.
          final path = Uri.decodeComponent(uri.toString());
          try {
            image = Image.file(
              File(path),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              cacheWidth: bubbleCacheWidth,
              cacheHeight: bubbleCacheHeight,
              errorBuilder: (context, error, stack) =>
                  _imageError(context, alt ?? path),
            );
          } catch (_) {
            image = _imageError(context, alt ?? path);
          }
        }

        return GestureDetector(
          onTap: () {
            if (isNetwork) {
              ImagePreviewPage.showNetwork(
                context,
                uri.toString(),
                title: title,
              );
            } else if (isFile) {
              ImagePreviewPage.showLocal(
                context,
                uri.toFilePath(),
                title: title,
              );
            }
          },
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
      ),
    );
  }
}

/// Shared error widget for broken images (network, file, data).
Widget _imageError(BuildContext context, String label) {
  return Container(
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
            label,
            style: TextStyle(fontSize: 12, color: context.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// Build an image widget from a `data:` URI (e.g. `data:image/png;base64,...`).
Widget _buildDataImage(
  BuildContext context,
  Uri uri,
  String? alt, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  try {
    final data = uri.toString();
    final comma = data.indexOf(',');
    if (comma == -1) return _imageError(context, alt ?? data);
    final raw = data.substring(comma + 1);
    final decoded = base64Decode(raw);
    return Image.memory(
      decoded,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      errorBuilder: (context, error, stack) =>
          _imageError(context, alt ?? data),
    );
  } catch (_) {
    return _imageError(context, alt ?? uri.toString());
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
