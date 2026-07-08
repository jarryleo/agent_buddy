import 'dart:convert';
import 'dart:io';

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
  Future<String> toBase64DataUrl(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw ImageServiceException('image file not found');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxImageBytes) {
      throw ImageServiceException(
        'image too large (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB, max '
        '${_maxImageBytes ~/ (1024 * 1024)} MB)',
      );
    }
    return 'data:${_guessMimeType(filePath)};base64,${base64Encode(bytes)}';
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
