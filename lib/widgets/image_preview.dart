import 'dart:io';

import 'package:flutter/material.dart';

class ImagePreviewPage extends StatelessWidget {
  const ImagePreviewPage({super.key, this.url, this.localPath, this.title})
    : assert(
        (url == null) != (localPath == null),
        'Provide exactly one of url or localPath',
      );

  final String? url;
  final String? localPath;
  final String? title;

  static void showNetwork(BuildContext context, String url, {String? title}) {
    _show(context, ImagePreviewPage(url: url, title: title));
  }

  static void showLocal(
    BuildContext context,
    String localPath, {
    String? title,
  }) {
    _show(context, ImagePreviewPage(localPath: localPath, title: title));
  }

  static void _show(BuildContext context, Widget page) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black87,
        barrierDismissible: true,
        pageBuilder: (_, _, _) => page,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Tri-linear mipmap filtering + a cache sized for InteractiveViewer's
    // max zoom (5x) on the device's physical pixels. Without FilterQuality.high
    // the bilinear default visibly smears detail when the user pinches in;
    // without a generous cacheWidth Flutter samples the GPU texture instead
    // of decoding at a higher resolution, which is the dominant cause of
    // "blurry image in the preview" complaints.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cacheSize = (MediaQuery.of(context).size.width * dpr * 5).round();
    final Widget image = (localPath != null)
        ? Image.file(
            File(localPath!),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            cacheWidth: cacheSize,
            cacheHeight: cacheSize,
            errorBuilder: (context, error, stack) => const Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 40,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Failed to load image',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          )
        : Image.network(
            url!,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            cacheWidth: cacheSize,
            cacheHeight: cacheSize,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  value: progress.expectedTotalBytes != null
                      ? progress.cumulativeBytesLoaded /
                            (progress.expectedTotalBytes ?? 1)
                      : null,
                  color: Colors.white,
                ),
              );
            },
            errorBuilder: (context, error, stack) => const Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 40,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Failed to load image',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: ColoredBox(color: Colors.black87),
            ),
          ),
          Center(
            child: InteractiveViewer(minScale: 1, maxScale: 5, child: image),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
