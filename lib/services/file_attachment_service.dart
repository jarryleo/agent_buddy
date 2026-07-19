import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/file_attachment.dart';
import 'tools/tool_base.dart' show isDesktopForRuntime;

class FileAttachmentService {
  /// [docsDirResolver] returns the application documents
  /// directory on platforms where the service still copies
  /// attachments into the app sandbox (Android / iOS). Defaults
  /// to `getApplicationDocumentsDirectory`. Exposed for unit
  /// tests so they can point at a `Directory.systemTemp` tempdir
  /// without having to install a `PathProviderPlatform` mock.
  FileAttachmentService({Future<Directory> Function()? docsDirResolver})
    : _docsDirResolver = docsDirResolver ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _docsDirResolver;

  static const int maxFileBytes = 20 * 1024 * 1024;
  static const int maxTextBytes = 1024 * 1024;

  Future<List<ChatFileAttachment>> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result == null) return const [];
    final attachments = <ChatFileAttachment>[];
    for (var i = 0; i < result.files.length; i++) {
      attachments.add(await _persistPlatformFile(result.files[i], i));
    }
    return attachments;
  }

  Future<List<ChatFileAttachment>> importPaths(Iterable<String> paths) async {
    final list = paths.toList(growable: false);
    if (list.isEmpty) return const [];
    final attachments = <ChatFileAttachment>[];
    var index = 0;
    for (final path in list) {
      final file = File(path);
      if (!await file.exists()) continue;
      final size = await file.length();
      _checkSize(size, p.basename(path));
      attachments.add(
        await _attach(
          sourcePath: path,
          name: p.basename(path),
          size: size,
          index: index++,
        ),
      );
    }
    return attachments;
  }

  Future<PreparedFileAttachment> prepare(
    ChatFileAttachment attachment, {
    bool includeBinaryData = true,
  }) async {
    final isText = _isTextFile(attachment.name, attachment.mimeType);
    if (!isText && !includeBinaryData) {
      _checkSize(attachment.size, attachment.name);
      return PreparedFileAttachment(
        name: attachment.name,
        path: attachment.path,
        size: attachment.size,
        mimeType: attachment.mimeType,
      );
    }
    final Uint8List bytes;
    if (attachment.inlineBase64 != null) {
      bytes = base64Decode(attachment.inlineBase64!);
    } else {
      if (attachment.path.isEmpty) {
        throw FileAttachmentException('file data is unavailable');
      }
      final file = File(attachment.path);
      if (!await file.exists()) {
        throw FileAttachmentException('file not found: ${attachment.name}');
      }
      bytes = await file.readAsBytes();
    }
    _checkSize(bytes.length, attachment.name);
    if (isText) {
      final truncated = bytes.length > maxTextBytes;
      final textBytes = truncated ? bytes.sublist(0, maxTextBytes) : bytes;
      final text = utf8.decode(textBytes, allowMalformed: true);
      return PreparedFileAttachment(
        name: attachment.name,
        path: attachment.path,
        size: bytes.length,
        mimeType: attachment.mimeType,
        textContent: truncated
            ? '$text\n\n[File truncated at ${maxTextBytes ~/ 1024} KB]'
            : text,
      );
    }
    return PreparedFileAttachment(
      name: attachment.name,
      path: attachment.path,
      size: bytes.length,
      mimeType: attachment.mimeType,
      base64Data: includeBinaryData ? base64Encode(bytes) : null,
    );
  }

  Future<ChatFileAttachment> _persistPlatformFile(
    PlatformFile file,
    int index,
  ) async {
    _checkSize(file.size, file.name);
    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw FileAttachmentException('file data is unavailable: ${file.name}');
      }
      return ChatFileAttachment(
        name: file.name,
        path: '',
        size: bytes.length,
        mimeType: _mimeType(file.name),
        inlineBase64: base64Encode(bytes),
      );
    }
    final sourcePath = file.path;
    if (sourcePath == null || sourcePath.isEmpty) {
      throw FileAttachmentException('file path is unavailable: ${file.name}');
    }
    return _attach(
      sourcePath: sourcePath,
      name: file.name,
      size: file.size,
      index: index,
    );
  }

  /// Returns a [ChatFileAttachment] pointing at the source file.
  ///
  /// On desktop (Windows / macOS / Linux) the file is **not**
  /// copied — the user-selected absolute path is forwarded to
  /// the model verbatim, so `file` tool calls (read / edit /
  /// write) operate on the user's actual file. The chat input
  /// carries no side-channel copy; subsequent re-sends of the
  /// same session re-read from the same path.
  ///
  /// On mobile (Android / iOS) the file is copied into
  /// `<docsDir>/chat_files/<µs>_<index>__<safeName>` because
  /// the picker hands back a transient URI that disappears as
  /// soon as the user navigates away, and the app cannot reach
  /// files outside its own sandbox via absolute paths.
  Future<ChatFileAttachment> _attach({
    required String sourcePath,
    required String name,
    required int size,
    required int index,
  }) async {
    if (isDesktopForRuntime()) {
      return ChatFileAttachment(
        name: name,
        path: sourcePath,
        size: size,
        mimeType: _mimeType(name),
      );
    }
    final baseDir = await _docsDirResolver();
    final filesDir = Directory(p.join(baseDir.path, 'chat_files'));
    if (!await filesDir.exists()) {
      await filesDir.create(recursive: true);
    }
    final safeName = _safeName(name);
    final destination = p.join(
      filesDir.path,
      '${DateTime.now().microsecondsSinceEpoch}_$index'
      '__$safeName',
    );
    await File(sourcePath).copy(destination);
    return ChatFileAttachment(
      name: name,
      path: destination,
      size: size,
      mimeType: _mimeType(name),
    );
  }

  void _checkSize(int size, String name) {
    if (size > maxFileBytes) {
      throw FileAttachmentException(
        '$name is larger than ${maxFileBytes ~/ (1024 * 1024)} MB',
      );
    }
  }

  String _safeName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  String _mimeType(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.pdf':
        return 'application/pdf';
      case '.txt':
      case '.log':
        return 'text/plain';
      case '.md':
      case '.markdown':
        return 'text/markdown';
      case '.csv':
        return 'text/csv';
      case '.json':
        return 'application/json';
      case '.xml':
        return 'application/xml';
      case '.html':
      case '.htm':
        return 'text/html';
      case '.yaml':
      case '.yml':
        return 'application/yaml';
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.doc':
        return 'application/msword';
      case '.docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case '.xls':
        return 'application/vnd.ms-excel';
      case '.xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case '.ppt':
        return 'application/vnd.ms-powerpoint';
      case '.pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case '.zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  bool _isTextFile(String name, String mimeType) {
    if (mimeType.startsWith('text/')) return true;
    const extensions = {
      '.c',
      '.cc',
      '.cpp',
      '.cs',
      '.css',
      '.dart',
      '.go',
      '.gradle',
      '.graphql',
      '.h',
      '.hpp',
      '.ini',
      '.java',
      '.js',
      '.jsx',
      '.json',
      '.kt',
      '.kts',
      '.lua',
      '.m',
      '.mm',
      '.php',
      '.properties',
      '.py',
      '.rb',
      '.rs',
      '.sh',
      '.sql',
      '.swift',
      '.toml',
      '.ts',
      '.tsx',
      '.vue',
      '.xml',
      '.yaml',
      '.yml',
    };
    return extensions.contains(p.extension(name).toLowerCase());
  }
}

class FileAttachmentException implements Exception {
  FileAttachmentException(this.message);

  final String message;

  @override
  String toString() => message;
}
