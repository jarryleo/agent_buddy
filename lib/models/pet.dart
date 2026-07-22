import 'dart:convert';

/// A single named animation strip on the pet's spritesheet.
///
/// The bundled spritesheet is a uniform grid: every cell is the same
/// size (`frameWidth × frameHeight`). Each animation gets a
/// contiguous horizontal strip on one row; cells outside the strip
/// are blank padding.
///
/// Example:
///
/// ```json
/// {
///   "name": "idle",
///   "row": 0,
///   "frameCount": 6,
///   "loop": true
/// }
/// ```
class PetAnimation {
  const PetAnimation({
    required this.name,
    required this.row,
    required this.frameCount,
    this.loop = true,
  });

  /// Stable identifier. Lookup keys (the chat provider says
  /// `playOneShot('jump')`) target this value. Convention: lower
  /// snake_case.
  final String name;

  /// Zero-indexed row in the spritesheet.
  final int row;

  /// Number of frames in this animation. Must be >= 1.
  final int frameCount;

  /// `true` for ambient states (idle, waiting, review, run_*)
  /// that loop forever; `false` for one-shot reactions (waving,
  /// jumping, failed) that play once and then return to the
  /// default animation.
  final bool loop;

  factory PetAnimation.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      throw const FormatException('pet animation is missing required "name"');
    }
    final row = (json['row'] as num?)?.toInt() ?? 0;
    final frameCount = (json['frameCount'] as num?)?.toInt() ?? 1;
    final loop = json['loop'] as bool? ?? true;
    return PetAnimation(
      name: name,
      row: row,
      frameCount: frameCount <= 0 ? 1 : frameCount,
      loop: loop,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'row': row,
    'frameCount': frameCount,
    'loop': loop,
  };

  @override
  String toString() =>
      'PetAnimation(name=$name, row=$row, frameCount=$frameCount, loop=$loop)';
}

/// A pet profile. The pet lives in its own directory on disk so the
/// importer can drop the spritesheet + json side-by-side and the
/// model can resolve `spritesheetPath` (relative to the pet dir)
/// against [directoryPath] (absolute).
///
/// **Built-in pets** (e.g. the bundled `anya`) carry
/// `isBuiltIn = true` and `directoryPath = null` — their spritesheet
/// is loaded from `AssetBundle` via [assetSpritesheetPath] instead.
/// **User-imported pets** always have `directoryPath` set and
/// `assetSpritesheetPath = null`.
///
/// The animation table ([animations]) is a list of named strips
/// the chat provider / drag handler can play by name. The first
/// matching strip is used when looking up by name.
class Pet {
  const Pet({
    required this.id,
    required this.displayName,
    required this.description,
    required this.spritesheetRelPath,
    required this.frameWidth,
    required this.frameHeight,
    required this.animations,
    required this.defaultAnimation,
    this.fps = 4.0,
    this.scale = 1.0,
    this.directoryPath,
    this.assetSpritesheetPath,
    this.isBuiltIn = false,
  });

  /// Stable identifier. For built-ins this is prefixed with
  /// `builtin:` (e.g. `builtin:anya`) so it can never collide with a
  /// user-imported pet that happens to use the same id (e.g. a
  /// user-imported `anya.zip`).
  final String id;

  /// User-visible name (localised at import time — pets do not
  /// store per-locale copies of the name).
  final String displayName;

  /// Free-form description; surfaced in the pet list row.
  final String description;

  /// Path of the spritesheet relative to the pet's directory
  /// (e.g. `spritesheet.webp`). Resolved against [directoryPath]
  /// for user imports, or against the app's asset root for built-ins.
  final String spritesheetRelPath;

  /// Width of a single frame in source pixels.
  final int frameWidth;

  /// Height of a single frame in source pixels (== row stride).
  final int frameHeight;

  /// Default playback rate in frames per second. The chat provider
  /// only overrides this when an animation specifies its own rate
  /// in the JSON; today every animation shares the pet's rate.
  final double fps;

  /// Display-only zoom factor applied when rendering. Defaults to
  /// 1.0 (no scaling). Importers can raise this for larger pets.
  final double scale;

  /// Named animation strips. Looked up by [animationByName] for
  /// the chat provider / drag handler.
  final List<PetAnimation> animations;

  /// Name of the animation the pet returns to between events
  /// (typically `idle`). Must match an entry in [animations].
  final String defaultAnimation;

  /// Absolute path to the directory that holds the pet's assets on
  /// disk. Always set for user-imported pets, always `null` for
  /// built-ins (those come from the app's asset bundle).
  final String? directoryPath;

  /// Asset-bundle path of the spritesheet (e.g.
  /// `assets/pet/anya/spritesheet.webp`). Only set for built-ins.
  final String? assetSpritesheetPath;

  /// `true` for pets that ship with the app (the bundled `anya`
  /// today). Built-ins cannot be deleted; importers cannot reuse
  /// their ids thanks to the `builtin:` prefix.
  final bool isBuiltIn;

  /// Looks up an animation by name. Returns `null` when no such
  /// animation exists on this pet — callers must treat the absence
  /// as a silent no-op (a pet that doesn't know how to `waving`
  /// just stays in its default animation rather than throwing).
  PetAnimation? animationByName(String name) {
    for (final a in animations) {
      if (a.name == name) return a;
    }
    return null;
  }

  /// Resolves the absolute path of the spritesheet on disk for
  /// user-imported pets. Returns `null` for built-ins (use
  /// [assetSpritesheetPath] instead) or when [directoryPath] is
  /// missing.
  String? resolveAbsoluteSpritesheetPath() {
    if (directoryPath == null) return null;
    return '$directoryPath/$spritesheetRelPath';
  }

  Pet copyWith({
    String? displayName,
    String? description,
    String? spritesheetRelPath,
    int? frameWidth,
    int? frameHeight,
    double? fps,
    double? scale,
    List<PetAnimation>? animations,
    String? defaultAnimation,
  }) {
    return Pet(
      id: id,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      spritesheetRelPath: spritesheetRelPath ?? this.spritesheetRelPath,
      frameWidth: frameWidth ?? this.frameWidth,
      frameHeight: frameHeight ?? this.frameHeight,
      fps: fps ?? this.fps,
      scale: scale ?? this.scale,
      animations: animations ?? this.animations,
      defaultAnimation: defaultAnimation ?? this.defaultAnimation,
      directoryPath: directoryPath,
      assetSpritesheetPath: assetSpritesheetPath,
      isBuiltIn: isBuiltIn,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'description': description,
    'spritesheetPath': spritesheetRelPath,
    'frameWidth': frameWidth,
    'frameHeight': frameHeight,
    'fps': fps,
    'scale': scale,
    'animations': animations.map((a) => a.toJson()).toList(),
    'defaultAnimation': defaultAnimation,
    'isBuiltIn': isBuiltIn,
    'directoryPath': directoryPath,
    'assetSpritesheetPath': assetSpritesheetPath,
  };

  factory Pet.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) {
      throw const FormatException('pet.json is missing required "id"');
    }
    final displayName = (json['displayName'] as String?)?.trim() ?? id;
    final description = (json['description'] as String?) ?? '';
    final spritesheetRelPath =
        (json['spritesheetPath'] as String?)?.trim() ?? 'spritesheet.webp';
    final frameWidth = _readInt(json['frameWidth']) ?? 200;
    final frameHeight = _readInt(json['frameHeight']) ?? 200;
    final fps = _readDouble(json['fps']) ?? 4.0;
    final scale = _readDouble(json['scale']) ?? 1.0;
    final isBuiltIn = json['isBuiltIn'] as bool? ?? false;

    final animationsJson = json['animations'];
    final List<PetAnimation> animations;
    if (animationsJson is List && animationsJson.isNotEmpty) {
      animations = animationsJson
          .whereType<Map<String, dynamic>>()
          .map(PetAnimation.fromJson)
          .toList();
    } else {
      // Backward-compat fallback for v1 manifests that only
      // declared a uniform grid. We synthesise a single `idle`
      // animation that covers the whole grid so the pet still
      // animates (just one strip instead of nine).
      final columns = _readInt(json['columns']) ?? 7;
      final rows = _readInt(json['rows']) ?? 1;
      final frames = (columns * rows).clamp(1, 1 << 20);
      animations = [
        PetAnimation(
          name: 'idle',
          row: 0,
          frameCount: frames,
          loop: true,
        ),
      ];
    }

    final defaultAnimation = (json['defaultAnimation'] as String?)?.trim();
    final resolvedDefault = defaultAnimation == null || defaultAnimation.isEmpty
        ? animations.first.name
        : defaultAnimation;

    return Pet(
      id: id,
      displayName: displayName,
      description: description,
      spritesheetRelPath: spritesheetRelPath,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      fps: fps,
      scale: scale,
      animations: animations,
      defaultAnimation: resolvedDefault,
      directoryPath: json['directoryPath'] as String?,
      assetSpritesheetPath: json['assetSpritesheetPath'] as String?,
      isBuiltIn: isBuiltIn,
    );
  }

  String toRawJson() => jsonEncode(toJson());
  factory Pet.fromRawJson(String raw) =>
      Pet.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  static int? _readInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static double? _readDouble(Object? v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  @override
  String toString() =>
      'Pet(id=$id, displayName=$displayName, animations=${animations.length})';
}