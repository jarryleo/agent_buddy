/// The high-level file categories a model can opt into receiving
/// as inline base64 (vs. path-only references). Used by
/// [ModelProvider.supportedFileTypes] to decide whether the chat
/// provider hands the model a decoded binary or just emits
/// `<attached_file path="…" />` so the model can pull the file
/// via the `file` tool.
///
/// The five categories map to the affordances the user sees in the
/// provider edit screen (text / image / audio / video / document).
enum AgentFileType { text, image, audio, video, document }

/// Map a file (by name + mime type) to one of the [AgentFileType]
/// categories. Returns `null` when the file doesn't match any
/// well-known category — callers should treat that as "unknown,
/// never send inline, only emit a path reference".
///
/// The categorization is deliberately conservative:
///   * `text/*` MIME types and a hand-curated set of common source
///     extensions fall into [AgentFileType.text].
///   * `image/*` MIME types fall into [AgentFileType.image].
///   * `audio/*` → [AgentFileType.audio].
///   * `video/*` → [AgentFileType.video].
///   * Everything else (PDFs, Office docs, archives, binaries with
///     no matching mime) → [AgentFileType.document]. This is the
///     "catch-all" the user sees in the settings UI.
/// The mime type takes priority when present; the extension is
/// only used as a fallback (the picker hands us a mime type on
/// every platform we care about, but the input box's "type a path"
/// path only has an extension to work with).
AgentFileType? categorizeFile({
  required String name,
  required String mimeType,
}) {
  final mt = mimeType.toLowerCase();
  if (mt.isNotEmpty && mt != 'application/octet-stream') {
    if (mt.startsWith('text/')) return AgentFileType.text;
    if (mt == 'application/json' ||
        mt == 'application/xml' ||
        mt == 'application/yaml' ||
        mt == 'application/javascript') {
      return AgentFileType.text;
    }
    if (mt.startsWith('image/')) return AgentFileType.image;
    if (mt.startsWith('audio/')) return AgentFileType.audio;
    if (mt.startsWith('video/')) return AgentFileType.video;
    return AgentFileType.document;
  }
  final ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.')).toLowerCase()
      : '';
  if (_textExtensions.contains(ext)) return AgentFileType.text;
  if (_imageExtensions.contains(ext)) return AgentFileType.image;
  if (_audioExtensions.contains(ext)) return AgentFileType.audio;
  if (_videoExtensions.contains(ext)) return AgentFileType.video;
  return AgentFileType.document;
}

const Set<String> _textExtensions = {
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
  '.htm',
  '.html',
  '.ini',
  '.java',
  '.js',
  '.jsx',
  '.json',
  '.kt',
  '.kts',
  '.lua',
  '.m',
  '.md',
  '.markdown',
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
  '.txt',
  '.vue',
  '.xml',
  '.yaml',
  '.yml',
  '.log',
  '.csv',
};

const Set<String> _imageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
};

const Set<String> _audioExtensions = {
  '.mp3',
  '.wav',
  '.flac',
  '.ogg',
  '.m4a',
  '.aac',
  '.opus',
  '.wma',
};

const Set<String> _videoExtensions = {
  '.mp4',
  '.mov',
  '.mkv',
  '.webm',
  '.avi',
  '.m4v',
  '.flv',
  '.wmv',
};
