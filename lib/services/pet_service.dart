import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
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

    Pet draft;
    try {
      draft = Pet.fromJson(raw);
    } on FormatException catch (e) {
      throw PetImportException(e.message);
    }
    if (draft.id.startsWith(builtinIdPrefix)) {
      throw PetImportException('内置宠物 id 以 $builtinIdPrefix 开头,不允许使用');
    }
    if (draft.id.isEmpty) {
      throw PetImportException('pet.json 缺少 id');
    }

    final manifestPath = _entryPath(manifestEntry);
    final manifestDirectory = p.posix.dirname(manifestPath);
    final archiveRoot = manifestDirectory == '.' ? '' : manifestDirectory;
    final sheetRel = _safeRelativePath(draft.spritesheetRelPath);
    if (sheetRel == null) {
      throw PetImportException('精灵图路径不合法 ${draft.spritesheetRelPath}');
    }
    final sheetArchivePath = archiveRoot.isEmpty
        ? sheetRel
        : p.posix.join(archiveRoot, sheetRel);
    final sheetEntry = _findEntry(archive, sheetArchivePath);
    if (sheetEntry == null) {
      throw PetImportException('找不到精灵图 ${draft.spritesheetRelPath}');
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
        await outFile.writeAsBytes(entry.content as List<int>);
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
    if (await manifestPath.exists()) {
      // Already seeded. Trust the on-disk copy (it carries the
      // user's tweaks, if any — we still only expose the
      // built-in id namespace).
      return;
    }
    await builtInDir.create(recursive: true);

    // Copy the spritesheet out of the asset bundle into the pet's
    // folder. This keeps the pet on disk so future window code
    // can read it via `FileImage` like a normal user import.
    final sheetBytes = await rootBundle.load(_builtinAnyaAssetSheet);
    final sheetOut = File(p.join(builtInDir.path, 'spritesheet.webp'));
    await sheetOut.writeAsBytes(
      sheetBytes.buffer.asUint8List(
        sheetBytes.offsetInBytes,
        sheetBytes.lengthInBytes,
      ),
    );

    // Materialise the manifest. We patch the asset-bundled JSON so
    // the importer's `directoryPath` / `assetSpritesheetPath` /
    // `isBuiltIn` are populated. If the bundled JSON is missing
    // (someone removed the asset), fall back to a synthetic record.
    Map<String, dynamic> raw;
    try {
      final manifestRaw = await rootBundle.loadString(_builtinAnyaAssetJson);
      raw = jsonDecode(manifestRaw) as Map<String, dynamic>;
    } catch (_) {
      raw = const {};
    }
    raw['id'] = builtInId;
    raw['displayName'] = raw['displayName'] ?? 'Anya';
    raw['description'] =
        raw['description'] ?? 'A digital pet version of Anya Forger.';
    raw['spritesheetPath'] = 'spritesheet.webp';
    raw['isBuiltIn'] = true;
    raw['directoryPath'] = builtInDir.path;
    raw.remove('assetSpritesheetPath');

    final stored = Pet.fromJson(raw);
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
        var pet = Pet.fromJson(raw);
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
