import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_buddy/services/image_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late ImageService svc;
  late img.Image fixture;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('image_service_test_');
    svc = ImageService();
    fixture = img.Image(width: 8, height: 8);
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        fixture.setPixelRgb(x, y, 255, 128, 64);
      }
    }
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  String pathIn(String name) => p.join(tempDir.path, name);

  void writeBytes(String name, Uint8List bytes) {
    File(pathIn(name)).writeAsBytesSync(bytes);
  }

  test('passes JPEG through unchanged (bytes preserved)', () async {
    final fp = pathIn('in.jpg');
    writeBytes('in.jpg', Uint8List.fromList(img.encodeJpg(fixture, quality: 90)));
    final expected = File(fp).readAsBytesSync();

    final dataUrl = await svc.toBase64DataUrl(fp);

    expect(dataUrl.startsWith('data:image/jpeg;base64,'), isTrue);
    final actual = base64Decode(
      dataUrl.substring('data:image/jpeg;base64,'.length),
    );
    expect(actual, expected);
  });

  test('passes PNG through unchanged (bytes preserved)', () async {
    final fp = pathIn('in.png');
    writeBytes('in.png', Uint8List.fromList(img.encodePng(fixture)));
    final expected = File(fp).readAsBytesSync();

    final dataUrl = await svc.toBase64DataUrl(fp);

    expect(dataUrl.startsWith('data:image/png;base64,'), isTrue);
    final actual = base64Decode(
      dataUrl.substring('data:image/png;base64,'.length),
    );
    expect(actual, expected);
  });

  test('transcodes WebP to JPEG@85', () async {
    final fp = pathIn('in.webp');
    writeBytes(
      'in.webp',
      Uint8List.fromList(img.WebPEncoder().encode(fixture)),
    );
    final originalBytes = File(fp).readAsBytesSync();

    final dataUrl = await svc.toBase64DataUrl(fp);

    expect(dataUrl.startsWith('data:image/jpeg;base64,'), isTrue);
    final actual = base64Decode(
      dataUrl.substring('data:image/jpeg;base64,'.length),
    );
    expect(actual, isNot(equals(originalBytes)));
    expect(img.decodeJpg(actual), isNotNull,
        reason: 'transcoded payload must decode as a real JPEG');
  });

  test('transcodes BMP to JPEG', () async {
    final fp = pathIn('in.bmp');
    writeBytes('in.bmp', Uint8List.fromList(img.encodeBmp(fixture)));

    final dataUrl = await svc.toBase64DataUrl(fp);

    expect(dataUrl.startsWith('data:image/jpeg;base64,'), isTrue);
    expect(img.decodeJpg(base64Decode(
      dataUrl.substring('data:image/jpeg;base64,'.length),
    )), isNotNull);
  });

  test('transcodes GIF (animated → first frame) to JPEG', () async {
    final fp = pathIn('in.gif');
    writeBytes('in.gif', Uint8List.fromList(img.encodeGif(fixture)));

    final dataUrl = await svc.toBase64DataUrl(fp);

    expect(dataUrl.startsWith('data:image/jpeg;base64,'), isTrue);
  });

  test('transcodes TIFF to JPEG', () async {
    final fp = pathIn('in.tiff');
    writeBytes('in.tiff', Uint8List.fromList(img.encodeTiff(fixture)));

    final dataUrl = await svc.toBase64DataUrl(fp);

    expect(dataUrl.startsWith('data:image/jpeg;base64,'), isTrue);
  });

  test('throws on undecodable bytes', () async {
    final fp = pathIn('garbage.webp');
    writeBytes('garbage.webp', Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]));
    await expectLater(
      svc.toBase64DataUrl(fp),
      throwsA(isA<ImageServiceException>()),
    );
  });

  test('throws on missing file', () async {
    final fp = pathIn('ghost.png');
    await expectLater(
      svc.toBase64DataUrl(fp),
      throwsA(isA<ImageServiceException>()),
    );
  });
}
