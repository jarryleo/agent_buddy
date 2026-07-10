class Memory {
  final String id;
  final String content;
  final String source;
  final DateTime createdAt;

  const Memory({
    required this.id,
    required this.content,
    required this.source,
    required this.createdAt,
  });

  Memory copyWith({String? content, String? source, DateTime? createdAt}) {
    return Memory(
      id: id,
      content: content ?? this.content,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'source': source,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
  };

  factory Memory.fromJson(Map<String, dynamic> json) {
    return Memory(
      id: json['id'] as String,
      content: json['content'] as String? ?? '',
      source: json['source'] as String? ?? 'user',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAtMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
