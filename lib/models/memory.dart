class Memory {
  final String id;
  final String content;
  final String source;
  final DateTime createdAt;

  /// Free-form tags / keywords the model attached to this memory
  /// to make future `search` calls cheaper. May be empty for
  /// memories written by hand (where the user typed content only)
  /// or for old v1 records persisted before this field existed.
  final List<String> tags;

  const Memory({
    required this.id,
    required this.content,
    required this.source,
    required this.createdAt,
    this.tags = const [],
  });

  Memory copyWith({
    String? content,
    String? source,
    DateTime? createdAt,
    List<String>? tags,
  }) {
    return Memory(
      id: id,
      content: content ?? this.content,
      source: source ?? this.source,
      createdAt: createdAt ?? this.createdAt,
      tags: tags ?? this.tags,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'source': source,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
    'tags': tags,
  };

  factory Memory.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    final tags = rawTags is List
        ? rawTags.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return Memory(
      id: json['id'] as String,
      content: json['content'] as String? ?? '',
      source: json['source'] as String? ?? 'user',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAtMs'] as num?)?.toInt() ?? 0,
      ),
      tags: tags,
    );
  }
}
