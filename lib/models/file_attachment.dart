class ChatFileAttachment {
  const ChatFileAttachment({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    this.inlineBase64,
  });

  final String name;
  final String path;
  final int size;
  final String mimeType;
  final String? inlineBase64;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'size': size,
    'mimeType': mimeType,
    if (inlineBase64 != null) 'inlineBase64': inlineBase64,
  };

  factory ChatFileAttachment.fromJson(Map<String, dynamic> json) {
    return ChatFileAttachment(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
      inlineBase64: json['inlineBase64'] as String?,
    );
  }
}

class PreparedFileAttachment {
  const PreparedFileAttachment({
    required this.name,
    required this.path,
    required this.size,
    required this.mimeType,
    this.textContent,
    this.base64Data,
  });

  final String name;
  final String path;
  final int size;
  final String mimeType;
  final String? textContent;
  final String? base64Data;

  String get dataUrl => 'data:$mimeType;base64,$base64Data';
}
