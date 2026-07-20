import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Handles picking images, persisting them to the app's documents
/// directory, and reading them back as base64 data URLs for the
/// multimodal API requests.
class ImageService {
  final ImagePicker _picker = ImagePicker();

  /// 20 MB ceiling. Even at 2048px / 85% quality most JPEGs come in
  /// well under 5 MB; this is just a guard against accidentally trying
  /// to upload a 50 MB photo album export.
  static const int _maxImageBytes = 20 * 1024 * 1024;

  /// Open the system gallery picker. Returns the absolute path of the
  /// copied file inside the app's documents directory, or `null` if
  /// the user cancelled.
  Future<String?> pickFromGallery() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (file == null) return null;
    return _copyIntoAppDir(file);
  }

  /// Open the system camera. Returns the absolute path of the saved
  /// photo, or `null` if the user cancelled. Requires camera permission
  /// to be declared in the host app's manifest / Info.plist.
  Future<String?> pickFromCamera() async {
    final XFile? file = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    if (file == null) return null;
    return _copyIntoAppDir(file);
  }

  Future<String> _copyIntoAppDir(XFile file) async {
    final baseDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(baseDir.path, 'chat_images'));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final ext = p.extension(file.path).toLowerCase();
    final safeExt = (ext.isNotEmpty && ext.length <= 5) ? ext : '.jpg';
    final destPath = p.join(
      imagesDir.path,
      'img_${DateTime.now().microsecondsSinceEpoch}$safeExt',
    );
    await File(file.path).copy(destPath);
    return destPath;
  }

  /// Read [filePath] from local storage and return a `data:` URL
  /// (e.g. `data:image/jpeg;base64,...`) suitable for OpenAI and
  /// Anthropic multimodal requests. Throws on missing/oversized files.
  ///
  /// JPEG and PNG are passed through unchanged. Anything else
  /// (WebP / GIF / BMP / TIFF / HEIC / …) is decoded with the
  /// `image` package and re-encoded as JPEG@85 so the payload is
  /// guaranteed to be readable by every OpenAI-compatible
  /// multimodal endpoint (most local mmproj processors only
  /// register JPEG / PNG decoders).
  Future<String> toBase64DataUrl(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ImageServiceException('image file not found');
    }
    final rawBytes = await file.readAsBytes();
    if (rawBytes.length > _maxImageBytes) {
      throw ImageServiceException(
        'image too large (${(rawBytes.length / 1024 / 1024).toStringAsFixed(1)} MB, max '
        '${_maxImageBytes ~/ (1024 * 1024)} MB)',
      );
    }

    final ext = p.extension(filePath).toLowerCase();
    if (_isPassthroughExt(ext)) {
      return 'data:${_guessMimeType(filePath)};base64,${base64Encode(rawBytes)}';
    }

    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) {
      throw ImageServiceException(
        'image could not be decoded (format "$ext" may be unsupported; '
        'try PNG or JPEG)',
      );
    }
    final encoded = Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
    return 'data:image/jpeg;base64,${base64Encode(encoded)}';
  }

  /// Whether [ext] is in the universally-supported set (JPEG / PNG)
  /// that we can forward to the backend without re-encoding.
  bool _isPassthroughExt(String ext) {
    switch (ext) {
      case '.jpg':
      case '.jpeg':
      case '.png':
        return true;
      default:
        return false;
    }
  }

  /// Guess the MIME type from the file extension. Falls back to JPEG.
  String _guessMimeType(String filePath) {
    switch (p.extension(filePath).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      default:
        return 'image/jpeg';
    }
  }

  void dispose() {}
}

class ImageServiceException implements Exception {
  ImageServiceException(this.message);
  final String message;
  @override
  String toString() => message;
}
