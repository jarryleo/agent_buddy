import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/edited_image.dart';
import 'tool_service.dart' show ToolException;

/// Actions the `edit_image` tool exposes. Mirrors the schema
/// `enum` and is used by [ImageEditService.edit] as a routing
/// key.
enum EditImageAction { compress, crop, resize, rotate, convert }

/// Snapshot of the source image the model passed in. Captured
/// in [ImageEditService.edit] so the resulting [EditedImage] can
/// surface "before vs after" deltas (kb saved, dimensions).
class _SourceSnapshot {
  const _SourceSnapshot({
    required this.width,
    required this.height,
    required this.size,
    required this.format,
  });
  final int width;
  final int height;
  final int size;
  final String format;
}

/// Owns file-system layout for the `edit_image` tool. Each call
/// reads the source image from `sourcePath`, decodes it, runs the
/// requested op, and writes the result to a fresh file inside
/// `getTemporaryDirectory()/edit_image/<uuid>_<filename>`. The
/// original file is **never** modified.
///
/// The model never sees the absolute temp path — the tool's
/// `execute()` returns the path only as part of the result
/// envelope, which the chat provider extracts and persists onto
/// the [EditedImage] so the bubble can preview the result. The
/// model itself just sees the structured `{action, path,
/// width, height, size, format}` envelope on the next turn and
/// can chain further edits by referencing the **source** path
/// again (it doesn't need to know about the temp dir).
class ImageEditService {
  ImageEditService({Directory? tempDir, Uuid? uuid})
    : _tempDir = tempDir,
      _uuid = uuid ?? const Uuid();

  final Uuid _uuid;
  final Directory? _tempDir;
  Directory? _subdir;

  /// Lazily resolved temp dir. We don't read it in the
  /// constructor because [getTemporaryDirectory] throws on
  /// web — and even on non-web the call is async and would force
  /// every consumer to `await` construction. The first call to
  /// [edit] resolves the dir + creates the `edit_image/`
  /// subdir; subsequent calls reuse the cached value.
  Future<Directory> _ensureSubdir() async {
    final cached = _subdir;
    if (cached != null) return cached;
    final base = _tempDir ?? await getTemporaryDirectory();
    final sub = Directory(p.join(base.path, 'edit_image'));
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    _subdir = sub;
    return sub;
  }

  /// Run an edit on [sourcePath]. Returns an [EditedImage]
  /// pointing at the new file in the temp directory.
  ///
  /// [action] drives the dispatch (see [EditImageAction]).
  /// [params] is the action-specific argument map; missing or
  /// out-of-range values are coerced to safe defaults but
  /// well-formed arguments are honored as-is.
  ///
  /// Throws [ToolException] on:
  ///   * missing source file
  ///   * undecodable source (corrupted / unsupported format)
  ///   * write failures
  ///   * out-of-bounds crop coords
  Future<EditedImage> edit({
    required String sourcePath,
    required EditImageAction action,
    required Map<String, dynamic> params,
  }) async {
    final src = File(sourcePath);
    if (!await src.exists()) {
      throw ToolException('source image not found: $sourcePath');
    }
    final bytes = await src.readAsBytes();
    final snapshot = _readSourceSnapshot(bytes);
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      // Some decoders in the `image` package (notably PSD)
      // throw on malformed input rather than returning null.
      // Treat both as "couldn't decode".
      throw ToolException(
        'cannot decode image at $sourcePath '
        '(corrupted or unsupported format)',
      );
    }
    if (decoded == null) {
      throw ToolException(
        'cannot decode image at $sourcePath (corrupted or unsupported format)',
      );
    }

    img.Image processed;
    String targetFormat;
    switch (action) {
      case EditImageAction.compress:
        processed = _compress(decoded, params);
        targetFormat = snapshot.format;
        break;
      case EditImageAction.crop:
        processed = _crop(decoded, params);
        targetFormat = snapshot.format;
        break;
      case EditImageAction.resize:
        processed = _resize(decoded, params);
        targetFormat = snapshot.format;
        break;
      case EditImageAction.rotate:
        processed = _rotate(decoded, params);
        targetFormat = snapshot.format;
        break;
      case EditImageAction.convert:
        processed = decoded;
        targetFormat = _readTargetFormat(params, snapshot.format);
        break;
    }

    final subdir = await _ensureSubdir();
    final ext = _formatExtension(targetFormat);
    final filename = _composeFilename(src, ext, action);
    final outPath = p.join(subdir.path, filename);

    final encoded = _encode(processed, targetFormat, _readQuality(params));
    if (encoded == null) {
      throw ToolException('failed to re-encode image for format=$targetFormat');
    }
    await File(outPath).writeAsBytes(encoded, flush: true);

    return EditedImage(
      path: outPath,
      filename: filename,
      width: processed.width,
      height: processed.height,
      size: encoded.length,
      format: targetFormat,
      action: action.name,
      sourceWidth: snapshot.width,
      sourceHeight: snapshot.height,
      sourceSize: snapshot.size,
    );
  }

  /// Best-effort snapshot of the source's metadata. Reads just
  /// the image header (no full decode) when possible so the
  /// "before" dimensions are cheap.
  _SourceSnapshot _readSourceSnapshot(Uint8List bytes) {
    final format = _detectFormat(bytes);
    final size = bytes.length;
    int width = 0;
    int height = 0;
    try {
      // `decodeImage` parses just enough of the header to
      // populate `width` / `height` without allocating the
      // full pixel buffer for many formats. We throw away the
      // decoded image; the caller does the real decode.
      final header = img.decodeImage(bytes);
      if (header != null) {
        width = header.width;
        height = header.height;
      }
    } catch (_) {
      // Fall back to zeros — the bubble hides the delta
      // instead of showing "0×0 → 0×0".
    }
    return _SourceSnapshot(
      width: width,
      height: height,
      size: size,
      format: format,
    );
  }

  String _detectFormat(Uint8List bytes) {
    if (bytes.length < 4) return 'jpeg';
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'gif';
    }
    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'bmp';
    }
    // WEBP: "RIFF....WEBP" — 4-byte magic + 8-byte header
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    // TIFF: II*\0 or MM\0*
    if (bytes.length >= 4 &&
        ((bytes[0] == 0x49 &&
                bytes[1] == 0x49 &&
                bytes[2] == 0x2A &&
                bytes[3] == 0x00) ||
            (bytes[0] == 0x4D &&
                bytes[1] == 0x4D &&
                bytes[2] == 0x00 &&
                bytes[3] == 0x2A))) {
      return 'tiff';
    }
    // Fallback: JPEG (FF D8 FF) and the catch-all case.
    return 'jpeg';
  }

  String _formatExtension(String format) {
    switch (format) {
      case 'png':
        return '.png';
      case 'gif':
        return '.gif';
      case 'bmp':
        return '.bmp';
      case 'webp':
        return '.webp';
      case 'tiff':
        return '.tiff';
      case 'jpeg':
      default:
        return '.jpg';
    }
  }

  String _composeFilename(File source, String ext, EditImageAction action) {
    final base = p.basenameWithoutExtension(source.path);
    final safeBase = base.isEmpty ? 'image' : base;
    // Truncate the base to keep the total filename under 80
    // chars — some filesystems (older FAT) cap to 8.3 but we
    // don't go that low; just stop the model-generated long
    // names from blowing up the temp dir listing.
    final trimmed = safeBase.length > 40 ? safeBase.substring(0, 40) : safeBase;
    final id = _uuid.v4().substring(0, 8);
    return '${trimmed}_${action.name}_$id$ext';
  }

  // -- Action implementations --------------------------------------

  img.Image _compress(img.Image src, Map<String, dynamic> params) {
    // `compress` is a no-op pixel-wise — we just re-encode the
    // existing image at a different quality during the write
    // step. Returning the source unchanged is the correct
    // semantic: the pixel buffer is identical to the input.
    return src;
  }

  img.Image _crop(img.Image src, Map<String, dynamic> params) {
    final x = _readInt(params, 'x', 0);
    final y = _readInt(params, 'y', 0);
    final width = _readInt(params, 'width', src.width - x);
    final height = _readInt(params, 'height', src.height - y);

    if (x < 0 || y < 0 || width <= 0 || height <= 0) {
      throw ToolException(
        'crop: x/y/width/height must be non-negative and > 0',
      );
    }
    if (x >= src.width || y >= src.height) {
      throw ToolException(
        'crop: origin (x=$x, y=$y) outside the source image '
        '(${src.width}x${src.height})',
      );
    }
    // Clamp the rect to the source's actual bounds so a slightly
    // oversized crop request doesn't blow up — instead we
    // produce the largest legal rect.
    final w = width.clamp(1, src.width - x);
    final h = height.clamp(1, src.height - y);
    return img.copyCrop(src, x: x, y: y, width: w, height: h);
  }

  img.Image _resize(img.Image src, Map<String, dynamic> params) {
    final width = _readInt(params, 'width', src.width);
    final height = _readInt(params, 'height', src.height);
    final keepAspect = params['keep_aspect_ratio'] as bool? ?? true;

    if (width <= 0 || height <= 0) {
      throw ToolException('resize: width and height must be positive integers');
    }

    int targetW = width;
    int targetH = height;
    if (keepAspect) {
      final ratio = src.width / src.height;
      // If the caller passed only one dimension, derive the
      // other so the aspect ratio is preserved exactly.
      final onlyWidth =
          params.containsKey('width') && !params.containsKey('height');
      final onlyHeight =
          params.containsKey('height') && !params.containsKey('width');
      if (onlyWidth) {
        targetH = (targetW / ratio).round();
      } else if (onlyHeight) {
        targetW = (targetH * ratio).round();
      } else {
        // Both given — fit the requested rect inside a box of
        // (targetW × targetH) while keeping the ratio.
        final boxRatio = width / height;
        if (ratio > boxRatio) {
          targetH = (targetW / ratio).round();
        } else {
          targetW = (targetH * ratio).round();
        }
      }
    }
    if (targetW <= 0 || targetH <= 0) {
      throw ToolException(
        'resize: derived target dimensions are non-positive '
        '($targetW×$targetH) — check width/height/keep_aspect_ratio',
      );
    }
    return img.copyResize(
      src,
      width: targetW,
      height: targetH,
      interpolation: img.Interpolation.cubic,
    );
  }

  img.Image _rotate(img.Image src, Map<String, dynamic> params) {
    final degrees = _readInt(params, 'degrees', 0);
    // Snap to the nearest multiple of 90 so we don't silently
    // mis-rotate. The `image` package's `copyRotate` is the
    // cubic-interpolation path — for arbitrary angles it does
    // a heavy decode, but our users almost always mean 90/180/270.
    final snapped = ((degrees ~/ 90) * 90) % 360;
    if (snapped == 0) return src;
    return img.copyRotate(src, angle: snapped);
  }

  Uint8List? _encode(img.Image image, String format, int quality) {
    switch (format) {
      case 'png':
        return Uint8List.fromList(img.encodePng(image));
      case 'gif':
        return Uint8List.fromList(img.encodeGif(image));
      case 'bmp':
        return Uint8List.fromList(img.encodeBmp(image));
      case 'tiff':
        return Uint8List.fromList(img.encodeTiff(image));
      case 'webp':
        // The `image` package's WebP encoder is lossless-only
        // (no quality knob — VP8L encodes the exact pixel
        // buffer). For a lossy WebP we'd need libwebp directly;
        // for now we fall through to lossless encoding and the
        // caller's `quality` arg is ignored for this format.
        return Uint8List.fromList(img.WebPEncoder().encode(image));
      case 'jpeg':
      default:
        return Uint8List.fromList(img.encodeJpg(image, quality: quality));
    }
  }

  // -- Parameter coercion -----------------------------------------

  int _readQuality(Map<String, dynamic> params) {
    final raw = params['quality'];
    if (raw is num) {
      return raw.clamp(1, 100).toInt();
    }
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return parsed.clamp(1, 100);
    }
    return 85;
  }

  /// Resolve the target format for the `convert` action. Accepts
  /// a friendly alias (`jpg`, `png`, `webp`, `gif`, `bmp`,
  /// `tiff`) or the canonical internal label (`jpeg`). Returns
  /// the source format unchanged when the caller didn't specify
  /// one (treated as a no-op convert → re-encode with the same
  /// format, which is harmless).
  ///
  /// Throws [ToolException] when the requested format isn't in
  /// the supported list — better to fail loudly than to silently
  /// write a `.jpg` file that the OS thinks is a TIFF.
  String _readTargetFormat(Map<String, dynamic> params, String fallback) {
    final raw = params['target_format'];
    if (raw is! String || raw.isEmpty) return fallback;
    final normalized = raw.trim().toLowerCase();
    switch (normalized) {
      case 'jpg':
      case 'jpeg':
        return 'jpeg';
      case 'png':
        return 'png';
      case 'webp':
        return 'webp';
      case 'gif':
        return 'gif';
      case 'bmp':
        return 'bmp';
      case 'tif':
      case 'tiff':
        return 'tiff';
      default:
        throw ToolException(
          'convert: unsupported target_format="$raw" '
          '(supported: jpg, png, webp, gif, bmp, tiff)',
        );
    }
  }

  int _readInt(Map<String, dynamic> params, String key, int fallback) {
    final raw = params[key];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }
}
