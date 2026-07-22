import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/pet.dart';

/// Thrown when a `.zip` import fails for any reason the user should
/// see (bad archive, missing `pet.json`, missing spritesheet, etc.).
class PetImportException implements Exception {
  PetImportException(this.message);
  final String message;

  @override
  String toString() => 'PetImportException: $message';
}

/// The user-visible entry-point for the desktop pet feature.
///
/// Owns the pet directory on disk and exposes a snapshot of the
/// current pet list (built-in + user-imported). Built-ins are
/// seeded on the first call to [ensureReady] — we materialise the
/// bundled `anya` from `AssetBundle` into the user pet directory so
/// the spritesheet lives next to imported pets (and so we can edit
/// the manifest once without re-reading the asset).
class PetService {
  PetService({Directory? appDir, Uuid? uuid})
    : _appDirOverride = appDir,
      _uuid = uuid ?? const Uuid();

  static const String _userPetFolder = 'pets';
  static const String _manifestFileName = 'pets.json';
  static const String _builtinAnyaAssetJson = 'assets/pet/anya/pet.json';
  static const String _builtinAnyaAssetSheet =
      'assets/pet/anya/spritesheet.webp';

  /// Marker prefix on built-in pet ids (`builtin:anya`) so a
  /// user-imported `anya.zip` cannot collide with the seeded one.
  static const String builtinIdPrefix = 'builtin:';

  final Uuid _uuid;
  final Directory? _appDirOverride;

  Directory? _petDir;
  List<Pet> _cache = const [];
  bool _ready = false;

  bool get isReady => _ready;

  /// Top-level pet directory inside the app's documents dir.
  /// Created on the first call to [ensureReady].
  Future<Directory> petDirectory() async {
    final dir = _petDir;
    if (dir != null) return dir;
    final base = _appDirOverride ?? await getApplicationDocumentsDirectory();
    final target = Directory(p.join(base.path, _userPetFolder));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    _petDir = target;
    return target;
  }

  /// Loads the on-disk manifest, materialises the bundled `anya`
  /// if it isn't there yet, and primes the in-memory cache.
  ///
  /// Safe to call multiple times — subsequent calls are a no-op
  /// once the initial seed is done.
  Future<List<Pet>> ensureReady() async {
    if (_ready) return _cache;
    final dir = await petDirectory();
    await _seedBuiltInAnya(dir);
    final manifest = await _readManifest(dir);
    final user = await _discoverUserPets(dir);
    final petsById = <String, Pet>{};
    for (final pet in manifest.where((pet) => pet.isBuiltIn)) {
      petsById[pet.id] = pet;
    }
    for (final pet in user) {
      petsById[pet.id] = pet;
    }
    _cache = petsById.values.toList();
    _ready = true;
    return _cache;
  }

  /// Returns the cached list of pets. The list always contains the
  /// built-in `anya` first, followed by user imports in
  /// newest-first order. Returns an empty list before
  /// [ensureReady] has been awaited — callers in the UI always go
  /// through the provider which awaits [ensureReady] on first read.
  List<Pet> list() => List.unmodifiable(_cache);

  /// Look up a pet by id. Returns `null` when no pet matches
  /// (e.g. the user deleted an active pet from another window).
  Pet? get(String id) {
    if (id.isEmpty) return null;
    for (final pet in _cache) {
      if (pet.id == id) return pet;
    }
    return null;
  }

  /// The built-in Anya, always present after [ensureReady].
  Pet? get builtInAnya {
    for (final pet in _cache) {
      if (pet.isBuiltIn) return pet;
    }
    return null;
  }

  /// Import a pet archive. The archive must be a `.zip` containing a
  /// `pet.json` manifest and the spritesheet file referenced by its
  /// `spritesheetPath` key.
  ///
  /// Returns the newly-imported pet. Throws [PetImportException]
  /// on any validation failure so the caller can surface a friendly
  /// message in the UI.
  Future<Pet> importFromZip(String zipPath) async {
    final dir = await petDirectory();
    final file = File(zipPath);
    if (!await file.exists()) {
      throw PetImportException('找不到文件:$zipPath');
    }
    final bytes = await file.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw PetImportException('无法解压 zip 文件:$e');
    }

    final manifestEntry = _findManifestEntry(archive);
    if (manifestEntry == null) {
      throw PetImportException('zip 里缺少 pet.json');
    }
    final manifestJson = utf8.decode(
      manifestEntry.content as List<int>,
      allowMalformed: true,
    );
    final Map<String, dynamic> raw;
    try {
      raw = jsonDecode(manifestJson) as Map<String, dynamic>;
    } catch (e) {
      throw PetImportException('pet.json 解析失败:$e');
    }

    final manifestPath = _entryPath(manifestEntry);
    final manifestDirectory = p.posix.dirname(manifestPath);
    final archiveRoot = manifestDirectory == '.' ? '' : manifestDirectory;
    final declaredSheet = _readManifestString(raw, const [
      'spritesheetPath',
      'spriteSheetPath',
      'sprite_sheet_path',
      'spritesheet',
      'spriteSheet',
      'sprite_sheet',
      'imagePath',
      'image_path',
      'image',
    ]);
    final sheetEntry = _resolveSpritesheetEntry(
      archive,
      archiveRoot: archiveRoot,
      declaredRelPath: declaredSheet,
    );
    if (sheetEntry == null) {
      final suffix = declaredSheet == null ? '' : ' ${declaredSheet.trim()}';
      throw PetImportException('找不到精灵图$suffix');
    }
    final sheetRel = _relativeEntryPath(sheetEntry, archiveRoot);
    if (sheetRel == null) {
      throw PetImportException('精灵图路径不合法 ${_entryPath(sheetEntry)}');
    }
    final sheetBytes = _entryBytes(sheetEntry);
    final normalizedRaw = _normalizeManifestForSheet(
      raw,
      fallbackId: _fallbackIdForImport(zipPath),
      spritesheetRelPath: sheetRel,
      sheetBytes: sheetBytes,
    );
    Pet draft;
    try {
      draft = Pet.fromJson(normalizedRaw);
    } on FormatException catch (e) {
      throw PetImportException(e.message);
    }
    if (draft.id.startsWith(builtinIdPrefix)) {
      throw PetImportException('内置宠物 id 以 $builtinIdPrefix 开头,不允许使用');
    }

    final petId = _uuid.v4();
    final petFolder = Directory(p.join(dir.path, petId));
    if (await petFolder.exists()) {
      await petFolder.delete(recursive: true);
    }
    await petFolder.create(recursive: true);

    try {
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final archivePath = _entryPath(entry);
        final relativePath = archiveRoot.isEmpty
            ? archivePath
            : p.posix.relative(archivePath, from: archiveRoot);
        final safePath = _safeRelativePath(relativePath);
        if (safePath == null) continue;
        final outPath = p.joinAll([petFolder.path, ...p.posix.split(safePath)]);
        final outFile = File(outPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(_entryBytes(entry));
      }

      final stored = draft.copyWithPetId(
        petId,
        directoryPath: petFolder.path,
        spritesheetRelPath: sheetRel,
      );
      await _persist(petFolder, stored);
      _cache = [stored, ..._cache.where((p) => p.id != petId)];
      return stored;
    } catch (e) {
      if (await petFolder.exists()) {
        await petFolder.delete(recursive: true);
      }
      if (e is PetImportException) rethrow;
      throw PetImportException('解压桌宠文件失败:$e');
    }
  }

  /// Removes a user-imported pet from disk and cache. Built-ins
  /// throw — the UI prevents the call entirely.
  Future<void> delete(String id) async {
    final pet = get(id);
    if (pet == null) return;
    if (pet.isBuiltIn) {
      throw PetImportException('内置宠物不可删除');
    }
    final folder = pet.directoryPath;
    if (folder != null) {
      final dir = Directory(folder);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    final dir = await petDirectory();
    final manifest = await _readManifest(dir);
    final updated = manifest.where((p) => p.id != id).toList();
    await _writeManifest(dir, updated);
    _cache = _cache.where((p) => p.id != id).toList();
  }

  // ---- internals ------------------------------------------------------

  Future<void> _seedBuiltInAnya(Directory dir) async {
    final builtInId = '${builtinIdPrefix}anya';
    final builtInDirName = _safeFolderName(builtInId);
    final builtInDir = Directory(p.join(dir.path, builtInDirName));
    final manifestPath = File(p.join(builtInDir.path, 'pet.json'));
    await builtInDir.create(recursive: true);

    // Copy the spritesheet out of the asset bundle into the pet's
    // folder. This keeps the pet on disk so future window code
    // can read it via `FileImage` like a normal user import.
    final sheetBytes = await rootBundle.load(_builtinAnyaAssetSheet);
    final sheetOut = File(p.join(builtInDir.path, 'spritesheet.webp'));
    final sheetByteList = sheetBytes.buffer.asUint8List(
      sheetBytes.offsetInBytes,
      sheetBytes.lengthInBytes,
    );
    if (!await sheetOut.exists()) {
      await sheetOut.writeAsBytes(sheetByteList);
    }

    // Materialise or repair the manifest through the same
    // petdex-compatible path used by zip imports. Older app builds
    // may have seeded a minimal Anya manifest; rewriting here adds
    // inferred frame metrics and the shared action table without
    // depending on Anya-specific parameters.
    Map<String, dynamic> raw;
    if (await manifestPath.exists()) {
      try {
        raw =
            jsonDecode(await manifestPath.readAsString())
                as Map<String, dynamic>;
      } catch (_) {
        raw = const {};
      }
    } else {
      try {
        final manifestRaw = await rootBundle.loadString(_builtinAnyaAssetJson);
        raw = jsonDecode(manifestRaw) as Map<String, dynamic>;
      } catch (_) {
        raw = const {};
      }
    }

    final normalized = _normalizeManifestForSheet(
      raw,
      fallbackId: builtInId,
      spritesheetRelPath: 'spritesheet.webp',
      sheetBytes: sheetByteList,
    );
    normalized['id'] = builtInId;
    if (_readManifestString(raw, const [
          'displayName',
          'display_name',
          'name',
          'title',
        ]) ==
        null) {
      normalized['displayName'] = 'Anya';
    }
    if (_readManifestString(raw, const ['description', 'desc']) == null) {
      normalized['description'] = 'A digital pet version of Anya Forger.';
    }
    normalized['isBuiltIn'] = true;
    normalized['directoryPath'] = builtInDir.path;
    normalized.remove('assetSpritesheetPath');

    final stored = Pet.fromJson(normalized);
    await manifestPath.writeAsString(jsonEncode(stored.toJson()));
  }

  /// Maps a pet id (`builtin:anya`, `momo`, …) to a folder name
  /// that is safe on every platform. The colon in the built-in
  /// prefix is invalid on Windows; we replace it (and any other
  /// path-illegal character) with `_` and keep the human-readable
  /// tail so the folder still looks recognisable.
  String _safeFolderName(String id) {
    const invalid = <String>['\\', '/', ':', '*', '?', '"', '<', '>', '|'];
    var out = id;
    for (final ch in invalid) {
      out = out.replaceAll(ch, '_');
    }
    return out;
  }

  Future<List<Pet>> _readManifest(Directory dir) async {
    final manifestFile = File(p.join(dir.path, _manifestFileName));
    if (!await manifestFile.exists()) return const [];
    try {
      final raw = await manifestFile.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map((m) {
            try {
              return Pet.fromJson(m);
            } catch (_) {
              return null;
            }
          })
          .whereType<Pet>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _writeManifest(Directory dir, List<Pet> pets) async {
    final manifestFile = File(p.join(dir.path, _manifestFileName));
    final payload = jsonEncode(pets.map((p) => p.toJson()).toList());
    await manifestFile.writeAsString(payload);
  }

  Future<List<Pet>> _discoverUserPets(Directory dir) async {
    final manifest = await _readManifest(dir);
    final byId = {for (final pet in manifest) pet.id: pet};
    final out = <Pet>[];
    final entries = await dir.list().toList();
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final manifestFile = File(p.join(entry.path, 'pet.json'));
      if (!await manifestFile.exists()) continue;
      try {
        final raw =
            jsonDecode(await manifestFile.readAsString())
                as Map<String, dynamic>;
        final declaredSheet = _readManifestString(raw, const [
          'spritesheetPath',
          'spriteSheetPath',
          'sprite_sheet_path',
          'spritesheet',
          'spriteSheet',
          'sprite_sheet',
          'imagePath',
          'image_path',
          'image',
        ]);
        final sheetRel = _safeRelativePath(declaredSheet ?? 'spritesheet.webp');
        var normalized = raw;
        if (sheetRel != null) {
          final sheetFile = File(
            p.joinAll([entry.path, ...p.posix.split(sheetRel)]),
          );
          if (await sheetFile.exists()) {
            normalized = _normalizeManifestForSheet(
              raw,
              fallbackId: p.basename(entry.path),
              spritesheetRelPath: sheetRel,
              sheetBytes: await sheetFile.readAsBytes(),
            );
          }
        }
        var pet = Pet.fromJson(normalized);
        if (byId.containsKey(pet.id)) {
          pet = byId[pet.id]!;
        }
        out.add(pet);
      } catch (_) {
        // Skip unparseable folder rather than blow up the whole list.
      }
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  Future<void> _persist(Directory petFolder, Pet pet) async {
    final manifestFile = File(p.join(petFolder.path, 'pet.json'));
    await manifestFile.writeAsString(jsonEncode(pet.toJson()));
    final dir = await petDirectory();
    final manifest = await _readManifest(dir);
    final next = [...manifest.where((m) => m.id != pet.id), pet];
    await _writeManifest(dir, next);
  }

  ArchiveFile? _findManifestEntry(Archive archive) {
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = _entryPath(entry);
      if (p.posix.basename(name) == 'pet.json') {
        return entry;
      }
    }
    return null;
  }

  ArchiveFile? _findEntry(Archive archive, String relPath) {
    final normalized = _safeRelativePath(relPath);
    if (normalized == null) return null;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (_entryPath(entry) == normalized) return entry;
    }
    return null;
  }

  ArchiveFile? _resolveSpritesheetEntry(
    Archive archive, {
    required String archiveRoot,
    required String? declaredRelPath,
  }) {
    final declared = declaredRelPath?.trim();
    if (declared != null && declared.isNotEmpty) {
      final safe = _safeRelativePath(declared);
      if (safe == null) {
        throw PetImportException('精灵图路径不合法 $declared');
      }
      final archivePath = archiveRoot.isEmpty
          ? safe
          : p.posix.join(archiveRoot, safe);
      final direct = _findEntry(archive, archivePath);
      if (direct != null) return direct;
    }

    final candidates = <ArchiveFile>[];
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final rel = _relativeEntryPath(entry, archiveRoot);
      if (rel == null) continue;
      if (!_isSupportedSpritesheetPath(rel)) continue;
      candidates.add(entry);
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final ap = p.posix.basename(_entryPath(a)).toLowerCase();
      final bp = p.posix.basename(_entryPath(b)).toLowerCase();
      return _spritesheetNameScore(bp).compareTo(_spritesheetNameScore(ap));
    });
    return candidates.first;
  }

  String? _relativeEntryPath(ArchiveFile entry, String archiveRoot) {
    final archivePath = _entryPath(entry);
    final relativePath = archiveRoot.isEmpty
        ? archivePath
        : p.posix.relative(archivePath, from: archiveRoot);
    return _safeRelativePath(relativePath);
  }

  bool _isSupportedSpritesheetPath(String path) {
    final parts = p.posix.split(path);
    if (parts.any(
      (part) => part.startsWith('__MACOSX') || part.startsWith('.'),
    )) {
      return false;
    }
    final ext = p.posix.extension(path).toLowerCase();
    return ext == '.png' || ext == '.webp';
  }

  int _spritesheetNameScore(String basename) {
    var score = 0;
    if (basename == 'spritesheet.png' || basename == 'spritesheet.webp') {
      score += 100;
    }
    if (basename.contains('spritesheet')) score += 50;
    if (basename.contains('sprite')) score += 30;
    if (basename.contains('sheet')) score += 20;
    return score;
  }

  Map<String, dynamic> _normalizeManifestForSheet(
    Map<String, dynamic> raw, {
    required String fallbackId,
    required String spritesheetRelPath,
    required List<int> sheetBytes,
  }) {
    final normalized = Map<String, dynamic>.from(raw);
    normalized['id'] =
        _readManifestString(normalized, const ['id']) ??
        _slugify(
          _readManifestString(normalized, const [
                'displayName',
                'display_name',
                'name',
                'title',
              ]) ??
              fallbackId,
        );
    normalized['displayName'] =
        _readManifestString(normalized, const [
          'displayName',
          'display_name',
          'name',
          'title',
        ]) ??
        normalized['id'];
    normalized['spritesheetPath'] = spritesheetRelPath;
    normalized['fps'] ??= 4.0;
    normalized['scale'] ??= 1.0;
    normalized['defaultAnimation'] ??= 'idle';

    final dimensions = _decodeImageDimensions(sheetBytes);
    if (dimensions != null) {
      normalized['frameWidth'] ??= _inferFrameWidth(
        normalized,
        dimensions.width,
      );
      normalized['frameHeight'] ??= _inferFrameHeight(
        normalized,
        dimensions.height,
      );
    }
    return normalized;
  }

  ({int width, int height})? _decodeImageDimensions(List<int> bytes) {
    try {
      final decoded = img.decodeImage(Uint8List.fromList(bytes));
      if (decoded == null) return null;
      return (width: decoded.width, height: decoded.height);
    } catch (_) {
      return null;
    }
  }

  int _inferFrameWidth(Map<String, dynamic> raw, int imageWidth) {
    final existing =
        _readInt(raw['frameWidth']) ?? _readInt(raw['frame_width']);
    if (existing != null && existing > 0) return existing;
    final columns = _readInt(raw['columns']) ?? Pet.standardColumns;
    if (columns > 0 && imageWidth % columns == 0) {
      return imageWidth ~/ columns;
    }
    return imageWidth;
  }

  int _inferFrameHeight(Map<String, dynamic> raw, int imageHeight) {
    final existing =
        _readInt(raw['frameHeight']) ?? _readInt(raw['frame_height']);
    if (existing != null && existing > 0) return existing;
    final rows = _readInt(raw['rows']) ?? Pet.standardRows;
    if (rows > 0 && imageHeight % rows == 0) {
      return imageHeight ~/ rows;
    }
    return imageHeight;
  }

  String _fallbackIdForImport(String zipPath) {
    final stem = p.basenameWithoutExtension(zipPath);
    return _slugify(stem.isEmpty ? 'pet' : stem);
  }

  String _slugify(String raw) {
    final out = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return out.isEmpty ? 'pet' : out;
  }

  String? _readManifestString(Map<String, dynamic> raw, List<String> keys) {
    for (final key in keys) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  int? _readInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  Uint8List _entryBytes(ArchiveFile entry) {
    final content = entry.content as List<int>;
    if (content is Uint8List) return content;
    return Uint8List.fromList(content);
  }

  String _entryPath(ArchiveFile entry) {
    var path = entry.name.replaceAll('\\', '/');
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    return p.posix.normalize(path);
  }

  String? _safeRelativePath(String path) {
    final normalized = p.posix.normalize(path.replaceAll('\\', '/'));
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized == '..' ||
        p.posix.isAbsolute(normalized) ||
        normalized.startsWith('../')) {
      return null;
    }
    return normalized;
  }
}

extension on Pet {
  /// Convenience for the importer: keep the manifest fields the
  /// user supplied but stamp the freshly-minted directory path
  /// + the on-disk id.
  Pet copyWithPetId(
    String id, {
    required String directoryPath,
    required String spritesheetRelPath,
  }) {
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
      defaultAnimation: defaultAnimation,
      directoryPath: directoryPath,
      assetSpritesheetPath: null,
      isBuiltIn: false,
    );
  }
}
