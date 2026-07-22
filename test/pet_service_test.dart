import 'dart:convert';
import 'dart:io';

import 'package:agent_buddy/models/pet.dart';
import 'package:agent_buddy/services/pet_service.dart';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Stub of the platform asset bundle so the bundled Anya can be
/// read from disk in tests. `flutter test` doesn't ship the
/// project's `assets:` entries to the test host, so the seeder
/// would otherwise fail with "Asset not found".
class _FakeAssetLoader {
  _FakeAssetLoader._();
  static final Map<String, Uint8List> _bytes = {};
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    final sheetFile = File('assets/pet/anya/spritesheet.webp');
    final jsonFile = File('assets/pet/anya/pet.json');
    if (sheetFile.existsSync()) {
      _bytes['assets/pet/anya/spritesheet.webp'] = Uint8List.fromList(
        sheetFile.readAsBytesSync(),
      );
    }
    if (jsonFile.existsSync()) {
      _bytes['assets/pet/anya/pet.json'] = Uint8List.fromList(
        utf8.encode(jsonFile.readAsStringSync()),
      );
    }
    const channel = MethodChannel('flutter/assets');
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMessageHandler(channel.name, (message) async {
          if (message == null) return null;
          final key = utf8.decode(
            message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          final bytes = _bytes[key];
          if (bytes == null) return null;
          return ByteData.sublistView(bytes);
        });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _FakeAssetLoader.install();

  late Directory tempDir;
  late PetService service;

  Future<String> writePetZip({
    required String id,
    required String displayName,
    required String description,
    String sheetRel = 'spritesheet.webp',
    Uint8List? sheetBytes,
    Map<String, dynamic>? overrides,
  }) async {
    final archive = Archive();
    final manifest = <String, dynamic>{
      'id': id,
      'displayName': displayName,
      'description': description,
      'spritesheetPath': sheetRel,
      if (overrides != null) ...overrides,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(
      ArchiveFile('pet.json', manifestBytes.length, manifestBytes),
    );
    final sheet = sheetBytes ?? Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
    archive.addFile(ArchiveFile(sheetRel, sheet.length, sheet));
    final encoded = ZipEncoder().encode(archive);
    final out = File(p.join(tempDir.path, '$id.zip'));
    await out.writeAsBytes(encoded, flush: true);
    return out.path;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pet_service_test_');
    service = PetService(appDir: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('ensureReady seeds the bundled Anya as a built-in', () async {
    final pets = await service.ensureReady();
    final builtin = service.builtInAnya;
    expect(builtin, isNotNull);
    expect(builtin!.isBuiltIn, isTrue);
    expect(builtin.id, 'builtin:anya');
    expect(builtin.directoryPath, isNotNull);
    // The seeder should have copied the bundled spritesheet onto
    // disk so the runtime window can open it via FileImage.
    final sheetPath = builtin.resolveAbsoluteSpritesheetPath();
    expect(sheetPath, isNotNull);
    expect(File(sheetPath!).existsSync(), isTrue);
    // The seeded pet must show up in the list.
    expect(pets.any((p) => p.id == 'builtin:anya'), isTrue);
  });

  test('built-in seeding is idempotent', () async {
    await service.ensureReady();
    final first = service.builtInAnya!;
    final manifestFile = File(p.join(first.directoryPath!, 'pet.json'));
    final originalJson = await manifestFile.readAsString();
    final mutated = originalJson.replaceFirst(
      '"displayName":',
      '"displayName":"Renamed",',
    );
    await manifestFile.writeAsString(mutated);

    final service2 = PetService(appDir: tempDir);
    await service2.ensureReady();
    final manifestAgain = await manifestFile.readAsString();
    expect(manifestAgain, contains('Renamed'));
  });

  test('importFromZip rejects archives missing pet.json', () async {
    final archive = Archive();
    archive.addFile(ArchiveFile('orphan.txt', 4, utf8.encode('nope')));
    final encoded = ZipEncoder().encode(archive);
    final out = File(p.join(tempDir.path, 'orphan.zip'));
    await out.writeAsBytes(encoded);

    await service.ensureReady();
    expect(
      () => service.importFromZip(out.path),
      throwsA(isA<PetImportException>()),
    );
  });

  test('importFromZip rejects archives missing the spritesheet', () async {
    final archive = Archive();
    archive.addFile(
      ArchiveFile(
        'pet.json',
        utf8.encode('{"id":"x","spritesheetPath":"missing.webp"}').length,
        utf8.encode('{"id":"x","spritesheetPath":"missing.webp"}'),
      ),
    );
    final encoded = ZipEncoder().encode(archive);
    final out = File(p.join(tempDir.path, 'nosheet.zip'));
    await out.writeAsBytes(encoded);

    await service.ensureReady();
    expect(
      () => service.importFromZip(out.path),
      throwsA(isA<PetImportException>()),
    );
  });

  test('importFromZip rejects built-in-prefixed ids', () async {
    final path = await writePetZip(
      id: '${PetService.builtinIdPrefix}imposter',
      displayName: 'Imposter',
      description: 'Tries to use a built-in id prefix',
    );
    await service.ensureReady();
    expect(
      () => service.importFromZip(path),
      throwsA(isA<PetImportException>()),
    );
  });

  test('importFromZip extracts the archive and registers the pet', () async {
    final path = await writePetZip(
      id: 'momo',
      displayName: 'Momo',
      description: 'A cat that likes boxes.',
      overrides: {
        'fps': 12.0,
        'scale': 2.0,
        'defaultAnimation': 'idle',
        'animations': [
          {'name': 'idle', 'row': 0, 'frameCount': 4, 'loop': true},
          {'name': 'jump', 'row': 1, 'frameCount': 5, 'loop': false},
        ],
      },
    );
    await service.ensureReady();
    final pet = await service.importFromZip(path);

    expect(pet.id, isNot('momo'));
    expect(pet.id.startsWith(PetService.builtinIdPrefix), isFalse);
    expect(pet.displayName, 'Momo');
    expect(pet.description, contains('boxes'));
    expect(pet.fps, 12.0);
    expect(pet.scale, 2.0);
    expect(pet.animations.length, 2);
    expect(pet.animationByName('idle')?.frameCount, 4);
    expect(pet.animationByName('jump')?.loop, isFalse);
    expect(pet.defaultAnimation, 'idle');
    expect(pet.isBuiltIn, isFalse);

    final petFolder = Directory(pet.directoryPath!);
    expect(await petFolder.exists(), isTrue);
    final files = await petFolder.list().toList();
    final names = files
        .whereType<File>()
        .map((f) => p.basename(f.path))
        .toList();
    expect(names, containsAll(<String>['pet.json', 'spritesheet.webp']));

    final all = service.list();
    expect(all.any((p) => p.displayName == 'Momo'), isTrue);
    expect(all.any((p) => p.isBuiltIn), isTrue);
  });

  test('importFromZip preserves paths relative to a nested manifest', () async {
    final archive = Archive();
    final manifestBytes = utf8.encode(
      jsonEncode({
        'id': 'nested',
        'displayName': 'Nested',
        'spritesheetPath': 'images/spritesheet.webp',
      }),
    );
    archive.addFile(
      ArchiveFile('nested-pet/pet.json', manifestBytes.length, manifestBytes),
    );
    final sheet = Uint8List.fromList([0x00, 0x01, 0x02, 0x03]);
    archive.addFile(
      ArchiveFile('nested-pet/images/spritesheet.webp', sheet.length, sheet),
    );
    final out = File(p.join(tempDir.path, 'nested.zip'));
    await out.writeAsBytes(ZipEncoder().encode(archive));

    await service.ensureReady();
    final pet = await service.importFromZip(out.path);

    expect(pet.spritesheetRelPath, 'images/spritesheet.webp');
    expect(File(pet.resolveAbsoluteSpritesheetPath()!).existsSync(), isTrue);
    expect(
      File(p.join(pet.directoryPath!, 'nested-pet', 'pet.json')).existsSync(),
      isFalse,
    );
  });

  test('ensureReady does not list the built-in pet twice', () async {
    final pets = await service.ensureReady();
    expect(pets.where((pet) => pet.id == 'builtin:anya'), hasLength(1));
  });

  test(
    'importFromZip rejects spritesheet paths escaping the pet root',
    () async {
      final archive = Archive();
      final manifestBytes = utf8.encode(
        jsonEncode({'id': 'unsafe', 'spritesheetPath': '../spritesheet.webp'}),
      );
      archive.addFile(
        ArchiveFile('pet/pet.json', manifestBytes.length, manifestBytes),
      );
      final out = File(p.join(tempDir.path, 'unsafe.zip'));
      await out.writeAsBytes(ZipEncoder().encode(archive));

      await service.ensureReady();
      expect(
        () => service.importFromZip(out.path),
        throwsA(isA<PetImportException>()),
      );
    },
  );

  test('delete removes the on-disk folder and the cache entry', () async {
    final path = await writePetZip(
      id: 'temp',
      displayName: 'Temp',
      description: '',
    );
    await service.ensureReady();
    final pet = await service.importFromZip(path);
    final folder = Directory(pet.directoryPath!);
    expect(await folder.exists(), isTrue);

    await service.delete(pet.id);
    expect(await folder.exists(), isFalse);
    expect(service.list().any((p) => p.id == pet.id), isFalse);
  });

  test('delete refuses to remove a built-in', () async {
    await service.ensureReady();
    final builtin = service.builtInAnya!;
    expect(
      () => service.delete(builtin.id),
      throwsA(isA<PetImportException>()),
    );
  });

  test(
    'Pet.fromJson synthesises a single idle animation when no animations list',
    () {
      final pet = Pet.fromJson(const {
        'id': 'minimal',
        'displayName': 'Minimal',
      });
      expect(pet.frameWidth, 200);
      expect(pet.frameHeight, 200);
      expect(pet.fps, 4.0);
      expect(pet.scale, 1.0);
      expect(pet.animations.length, 1);
      expect(pet.animations.first.name, 'idle');
      expect(pet.defaultAnimation, 'idle');
    },
  );

  test('Pet.fromJson honours explicit animations + defaultAnimation', () {
    final pet = Pet.fromJson(const {
      'id': 'momo',
      'displayName': 'Momo',
      'animations': [
        {'name': 'idle', 'row': 0, 'frameCount': 6, 'loop': true},
        {'name': 'jump', 'row': 1, 'frameCount': 5, 'loop': false},
      ],
      'defaultAnimation': 'idle',
    });
    expect(pet.animations.length, 2);
    expect(pet.animationByName('jump')?.frameCount, 5);
    expect(pet.animationByName('jump')?.loop, isFalse);
    expect(pet.animationByName('missing'), isNull);
    expect(pet.defaultAnimation, 'idle');
  });

  test('Pet.fromJson throws when id is missing', () {
    expect(
      () => Pet.fromJson(const {'displayName': 'no id'}),
      throwsA(isA<FormatException>()),
    );
  });

  test('Pet JSON round-trips', () {
    final src = Pet(
      id: 'x',
      displayName: 'X',
      description: 'd',
      spritesheetRelPath: 'sheet.webp',
      frameWidth: 64,
      frameHeight: 96,
      fps: 10,
      scale: 1.5,
      directoryPath: '/tmp/x',
      animations: const [
        PetAnimation(name: 'idle', row: 0, frameCount: 4, loop: true),
      ],
      defaultAnimation: 'idle',
    );
    final round = Pet.fromRawJson(src.toRawJson());
    expect(round.id, 'x');
    expect(round.frameWidth, 64);
    expect(round.frameHeight, 96);
    expect(round.fps, 10.0);
    expect(round.scale, 1.5);
    expect(round.directoryPath, '/tmp/x');
    expect(round.animations.length, 1);
    expect(round.animations.first.name, 'idle');
    expect(round.defaultAnimation, 'idle');
  });
}
