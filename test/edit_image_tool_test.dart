import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_buddy/models/edited_image.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/services/image_edit_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/edit_image_tool.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late File sourceJpeg;
  late File sourcePng;

  /// Generate a simple solid-color JPEG for tests. Avoids any
  /// dependency on a fixture folder + lets each test start from
  /// a known (width, height, color) baseline.
  Future<File> writeSyntheticJpeg({
    required int width,
    required int height,
    int r = 200,
    int g = 100,
    int b = 50,
  }) async {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(r, g, b));
    final bytes = img.encodeJpg(image, quality: 95);
    final file = File(p.join(tempDir.path, 'source.jpg'));
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File> writeSyntheticPng({
    required int width,
    required int height,
    int r = 80,
    int g = 120,
    int b = 200,
  }) async {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(r, g, b));
    final bytes = img.encodePng(image);
    final file = File(p.join(tempDir.path, 'source.png'));
    await file.writeAsBytes(bytes);
    return file;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_buddy_edit_img_');
    sourceJpeg = await writeSyntheticJpeg(width: 800, height: 600);
    sourcePng = await writeSyntheticPng(width: 800, height: 600);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Build a synthetic fixture suitable for flip tests.
  /// [axis] picks the colour boundary — `horizontal` (default)
  /// splits left/right; `vertical` splits top/bottom. Both
  /// halves get a strong, easy-to-detect colour (red vs blue)
  /// so the assertion can read individual pixels.
  Future<File> writeSplitPng({
    required int width,
    required int height,
    required String tempPath,
    String axis = 'horizontal',
  }) async {
    final image = img.Image(width: width, height: height, numChannels: 3);
    for (final p in image) {
      final isLeftOrTop = axis == 'vertical'
          ? (p.y < height ~/ 2)
          : (p.x < width ~/ 2);
      if (isLeftOrTop) {
        p
          ..r = 230
          ..g = 30
          ..b = 30;
      } else {
        p
          ..r = 30
          ..g = 30
          ..b = 230;
      }
    }
    final bytes = img.encodePng(image);
    final file = File(p.join(tempPath, 'split_${width}x$height$axis.png'));
    await file.writeAsBytes(bytes);
    return file;
  }

  group('EditedImage', () {
    test('round-trips through toJson / fromJson', () {
      final original = EditedImage(
        path: '/tmp/foo.jpg',
        filename: 'foo_compress_aabbccdd.jpg',
        width: 800,
        height: 600,
        size: 12345,
        format: 'jpeg',
        action: 'compress',
        sourceWidth: 800,
        sourceHeight: 600,
        sourceSize: 24500,
      );
      final restored = EditedImage.fromJson(original.toJson());
      expect(restored.path, original.path);
      expect(restored.filename, original.filename);
      expect(restored.width, original.width);
      expect(restored.height, original.height);
      expect(restored.size, original.size);
      expect(restored.format, original.format);
      expect(restored.action, original.action);
      expect(restored.sourceSize, original.sourceSize);
    });

    test('sizeDeltaPercent reports signed change when baseline is set', () {
      final shrunk = EditedImage(
        path: '/tmp/foo.jpg',
        filename: 'foo.jpg',
        width: 800,
        height: 600,
        size: 12000,
        format: 'jpeg',
        action: 'compress',
        sourceSize: 24000,
      );
      // (12000 - 24000) / 24000 = -0.5 → -50%
      expect(shrunk.sizeDeltaPercent, closeTo(-50.0, 0.1));
      expect(shrunk.shrankBytes, isTrue);
    });

    test('sizeDeltaPercent is null when baseline is missing', () {
      final noBaseline = EditedImage(
        path: '/tmp/foo.jpg',
        filename: 'foo.jpg',
        width: 800,
        height: 600,
        size: 12000,
        format: 'jpeg',
        action: 'compress',
      );
      expect(noBaseline.sizeDeltaPercent, isNull);
      expect(noBaseline.shrankBytes, isFalse);
    });
  });

  group('ImageEditService', () {
    test('compress on JPEG: writes a smaller file at lower quality', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final originalSize = await sourceJpeg.length();
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.compress,
        params: {'quality': 30},
      );
      expect(result.action, 'compress');
      expect(result.format, 'jpeg');
      expect(result.width, 800);
      expect(result.height, 600);
      expect(result.sourceSize, originalSize);
      final outFile = File(result.path);
      expect(await outFile.exists(), isTrue);
      expect(outFile.path, isNot(equals(sourceJpeg.path)));
      expect(result.size, lessThan(originalSize));
    });

    test('compress on PNG: keeps lossless PNG format', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourcePng.path,
        action: EditImageAction.compress,
        params: const {},
      );
      expect(result.format, 'png');
      expect(result.filename, endsWith('.png'));
      expect(File(result.path).existsSync(), isTrue);
    });

    test('crop: produces an image with the requested dimensions', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.crop,
        params: {'x': 100, 'y': 50, 'width': 400, 'height': 300},
      );
      expect(result.width, 400);
      expect(result.height, 300);
      expect(result.action, 'crop');
    });

    test('crop: throws when origin is outside the source', () async {
      final svc = ImageEditService(tempDir: tempDir);
      expect(
        () => svc.edit(
          sourcePath: sourceJpeg.path,
          action: EditImageAction.crop,
          params: {'x': 2000, 'y': 0, 'width': 100, 'height': 100},
        ),
        throwsA(isA<ToolException>()),
      );
    });

    test('crop: throws on non-positive dimensions', () async {
      final svc = ImageEditService(tempDir: tempDir);
      expect(
        () => svc.edit(
          sourcePath: sourceJpeg.path,
          action: EditImageAction.crop,
          params: {'x': 0, 'y': 0, 'width': 0, 'height': 100},
        ),
        throwsA(isA<ToolException>()),
      );
    });

    test('crop: clamps an oversized rect to the source bounds', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.crop,
        params: {'x': 700, 'y': 500, 'width': 9999, 'height': 9999},
      );
      // Source is 800x600 → crop rect is 100x100.
      expect(result.width, 100);
      expect(result.height, 100);
    });

    test('resize: produces an image with the requested dimensions', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.resize,
        params: {'width': 200, 'height': 150, 'keep_aspect_ratio': false},
      );
      expect(result.width, 200);
      expect(result.height, 150);
    });

    test(
      'resize: keep_aspect_ratio true with only width derives height',
      () async {
        final svc = ImageEditService(tempDir: tempDir);
        // 800x600 → 4:3 aspect → width=400 → height=300.
        final result = await svc.edit(
          sourcePath: sourceJpeg.path,
          action: EditImageAction.resize,
          params: {'width': 400, 'keep_aspect_ratio': true},
        );
        expect(result.width, 400);
        expect(result.height, 300);
      },
    );

    test('rotate 90: swaps width and height for a non-square image', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.rotate,
        params: {'degrees': 90},
      );
      expect(result.width, 600);
      expect(result.height, 800);
    });

    test('rotate 180: keeps dimensions for a square (sanity check)', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final square = await writeSyntheticJpeg(width: 500, height: 500);
      final result = await svc.edit(
        sourcePath: square.path,
        action: EditImageAction.rotate,
        params: {'degrees': 180},
      );
      expect(result.width, 500);
      expect(result.height, 500);
    });

    test('throws on missing source file', () async {
      final svc = ImageEditService(tempDir: tempDir);
      expect(
        () => svc.edit(
          sourcePath: p.join(tempDir.path, 'does-not-exist.jpg'),
          action: EditImageAction.crop,
          params: const {},
        ),
        throwsA(isA<ToolException>()),
      );
    });

    test('throws on corrupted file', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final junk = File(p.join(tempDir.path, 'junk.jpg'));
      await junk.writeAsBytes(Uint8List.fromList([0x00, 0x01, 0x02]));
      expect(
        () => svc.edit(
          sourcePath: junk.path,
          action: EditImageAction.crop,
          params: const {},
        ),
        throwsA(isA<ToolException>()),
      );
    });

    test('circle: produces a square image of the shortest side', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.circle,
        params: const {},
      );
      // 800x600 → square of side 600.
      expect(result.action, 'circle');
      expect(result.width, 600);
      expect(result.height, 600);
      expect(File(result.path).existsSync(), isTrue);
    });

    test(
      'circle: corner pixels are fully transparent in the saved PNG',
      () async {
        final svc = ImageEditService(tempDir: tempDir);
        final result = await svc.edit(
          sourcePath: sourcePng.path,
          action: EditImageAction.circle,
          params: const {},
        );
        // The PNG preserves alpha; reading it back through the
        // `image` package lets us assert on the mask directly.
        final bytes = await File(result.path).readAsBytes();
        final decoded = img.decodePng(bytes)!;
        expect(decoded.numChannels, 4);
        // top-left corner (well outside the inscribed circle)
        final corner = decoded.getPixel(0, 0);
        expect(corner.a.toInt(), 0);
        // centre is solidly opaque
        final center = decoded.getPixel(
          decoded.width ~/ 2,
          decoded.height ~/ 2,
        );
        expect(center.a.toInt(), 255);
      },
    );

    test('circle: radius_ratio shrinks the visible disc', () async {
      final svc = ImageEditService(tempDir: tempDir);
      // Use a smaller source so we can introspect the mask
      // without taking a million years; 200x200 = same
      // result, just compact.
      final src = await writeSyntheticPng(width: 200, height: 200);
      final result = await svc.edit(
        sourcePath: src.path,
        action: EditImageAction.circle,
        params: {'radius_ratio': 0.5},
      );
      final bytes = await File(result.path).readAsBytes();
      final decoded = img.decodePng(bytes)!;
      // `copyCropCircle` returns a square of side `2*radius`
      // — so radius_ratio=0.5 of a 200x200 input gives a
      // 100x100 output, not 200x200. The visible disc is
      // centred at (50, 50) with radius 50, so the four
      // corners (distance ≈ 70.7) are well outside the
      // mask and should be fully transparent.
      expect(decoded.width, 100);
      expect(decoded.height, 100);
      expect(decoded.numChannels, 4);
      // All four corners live outside the 50px-radius disc.
      for (final pos in const [
        [0, 0],
        [99, 0],
        [0, 99],
        [99, 99],
      ]) {
        final px = decoded.getPixel(pos[0], pos[1]);
        expect(px.a.toInt(), 0, reason: 'pixel (${pos[0]},${pos[1]})');
      }
      // Centre pixel is solidly inside the disc.
      final centre = decoded.getPixel(50, 50);
      expect(centre.a.toInt(), 255);
    });

    test('rounded_corners: keeps the same dimensions and dimensions', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourcePng.path,
        action: EditImageAction.roundedCorners,
        params: const {},
      );
      // The action string on the envelope is the camelCase enum
      // name (matches the rest of the actions' shape; the tool
      // accepts the snake_case alias on the way in).
      expect(result.action, 'roundedCorners');
      expect(result.width, 800);
      expect(result.height, 600);
    });

    test(
      'rounded_corners: corner pixels are transparent on a PNG source',
      () async {
        final svc = ImageEditService(tempDir: tempDir);
        // Use a small image so the mask boundary is easy to
        // reason about — radius (10% × 80) = 8px.
        final src = await writeSyntheticPng(width: 80, height: 80);
        final result = await svc.edit(
          sourcePath: src.path,
          action: EditImageAction.roundedCorners,
          params: {'radius_percent': 10},
        );
        final bytes = await File(result.path).readAsBytes();
        final decoded = img.decodePng(bytes)!;
        expect(decoded.numChannels, 4);
        // Exact (0,0) corner sits outside the arc → alpha 0.
        final corner = decoded.getPixel(0, 0);
        expect(corner.a.toInt(), 0);
        // Centre pixel sits deep inside the safe rectangle.
        final center = decoded.getPixel(40, 40);
        expect(center.a.toInt(), 255);
      },
    );

    test('rounded_corners: on a JPEG source auto-promotes to PNG so the '
        'transparent corners survive the round trip', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.roundedCorners,
        params: {'radius_percent': 5},
      );
      // JPEG can't carry alpha, so we promote to PNG
      // automatically — the whole point of this fix. The
      // bubble's preview would otherwise show opaque corners
      // (typically black, because JPEG composites onto a black
      // background by default) instead of a transparent mask.
      expect(result.format, 'png');
      expect(result.filename, endsWith('.png'));
      final outBytes = await File(result.path).readAsBytes();
      final decoded = img.decodePng(outBytes)!;
      expect(decoded.numChannels, 4);
      expect(decoded.width, 800);
      expect(decoded.height, 600);
      // The top-left corner is well outside the corner arc
      // (radius = 5% of 600 = 30px) so its alpha must be 0.
      final corner = decoded.getPixel(0, 0);
      expect(corner.a.toInt(), 0);
    });

    test('circle: on a JPEG source auto-promotes to PNG so the '
        'transparent corners survive the round trip', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.circle,
        params: const {},
      );
      // JPEG can't carry alpha, so the output must be PNG.
      expect(result.format, 'png');
      expect(result.filename, endsWith('.png'));
      final outBytes = await File(result.path).readAsBytes();
      final decoded = img.decodePng(outBytes)!;
      expect(decoded.numChannels, 4);
      // The corner is well outside the inscribed circle, so
      // its alpha must be 0 — the user's "round my JPEG into
      // a circle" request now actually produces a circular
      // preview.
      final corner = decoded.getPixel(0, 0);
      expect(corner.a.toInt(), 0);
    });

    test('rounded_corners: honors an explicit target_format override '
        '(even when that format can\'t hold alpha)', () async {
      final svc = ImageEditService(tempDir: tempDir);
      // Even though JPEG can't hold alpha, the caller asked
      // for a JPEG explicitly. We honor that — losing the
      // transparency is their trade-off to make, and downstream
      // tooling may depend on the format. This is the explicit
      // escape hatch next to the auto-promote.
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.roundedCorners,
        params: {'radius_percent': 5, 'target_format': 'jpg'},
      );
      expect(result.format, 'jpeg');
      expect(result.filename, endsWith('.jpg'));
      final outBytes = await File(result.path).readAsBytes();
      final decoded = img.decodeJpg(outBytes)!;
      expect(decoded.width, 800);
      expect(decoded.height, 600);
    });

    test('rounded_corners: keeps PNG format when source is PNG '
        '(no auto-promote needed — alpha already fits)', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourcePng.path,
        action: EditImageAction.roundedCorners,
        params: {'radius_percent': 10},
      );
      expect(result.format, 'png');
      expect(result.filename, endsWith('.png'));
    });

    test('circle: keeps WebP format when source is WebP '
        '(WebP supports alpha; no auto-promote needed)', () async {
      final svc = ImageEditService(tempDir: tempDir);
      // Build a small WebP source. `image` package's lossless
      // WebP encoder supports RGBA, so the source already
      // carries alpha and the output format doesn't have to
      // change.
      final src = img.Image(width: 100, height: 100, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(200, 100, 50, 255));
      final webpBytes = img.WebPEncoder().encode(src);
      final webpPath = p.join(tempDir.path, 'source.webp');
      await File(webpPath).writeAsBytes(webpBytes);

      final result = await svc.edit(
        sourcePath: webpPath,
        action: EditImageAction.circle,
        params: const {},
      );
      expect(result.format, 'webp');
      expect(result.filename, endsWith('.webp'));
    });

    test(
      'rounded_corners: radius_percent=0 keeps the image untouched',
      () async {
        final svc = ImageEditService(tempDir: tempDir);
        final result = await svc.edit(
          sourcePath: sourcePng.path,
          action: EditImageAction.roundedCorners,
          params: {'radius_percent': 0},
        );
        expect(File(result.path).existsSync(), isTrue);
        expect(result.width, 800);
        expect(result.height, 600);
      },
    );

    test('flip horizontal: pixels mirror left↔right', () async {
      final svc = ImageEditService(tempDir: tempDir);
      // Build a red/blue split image so flip is unambiguous.
      final src = await writeSplitPng(
        width: 100,
        height: 50,
        tempPath: tempDir.path,
      );
      final result = await svc.edit(
        sourcePath: src.path,
        action: EditImageAction.flip,
        params: {'direction': 'horizontal'},
      );
      final bytes = await File(result.path).readAsBytes();
      final decoded = img.decodePng(bytes)!;
      // Left half (originally red) is now blue; right half
      // (originally blue) is now red.
      final leftSample = decoded.getPixel(10, 10);
      final rightSample = decoded.getPixel(90, 10);
      expect(leftSample.b.toInt(), greaterThan(leftSample.r.toInt()));
      expect(rightSample.r.toInt(), greaterThan(rightSample.b.toInt()));
    });

    test('flip vertical: pixels mirror top↔bottom', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final src = await writeSplitPng(
        width: 50,
        height: 100,
        tempPath: tempDir.path,
        axis: 'vertical',
      );
      final result = await svc.edit(
        sourcePath: src.path,
        action: EditImageAction.flip,
        params: {'direction': 'vertical'},
      );
      final bytes = await File(result.path).readAsBytes();
      final decoded = img.decodePng(bytes)!;
      final topSample = decoded.getPixel(10, 10);
      final bottomSample = decoded.getPixel(10, 90);
      expect(topSample.b.toInt(), greaterThan(topSample.r.toInt()));
      expect(bottomSample.r.toInt(), greaterThan(bottomSample.b.toInt()));
    });

    test('flip both: dimensions are preserved', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final result = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.flip,
        params: {'direction': 'both'},
      );
      expect(result.action, 'flip');
      expect(result.width, 800);
      expect(result.height, 600);
    });

    test('flip throws on an unknown direction', () async {
      final svc = ImageEditService(tempDir: tempDir);
      expect(
        () => svc.edit(
          sourcePath: sourceJpeg.path,
          action: EditImageAction.flip,
          params: {'direction': 'diagonal'},
        ),
        throwsA(isA<ToolException>()),
      );
    });

    test('flip accepts the "v" / "h" aliases', () async {
      final svc = ImageEditService(tempDir: tempDir);
      final r1 = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.flip,
        params: {'direction': 'h'},
      );
      final r2 = await svc.edit(
        sourcePath: sourceJpeg.path,
        action: EditImageAction.flip,
        params: {'direction': 'v'},
      );
      expect(r1.action, 'flip');
      expect(r2.action, 'flip');
    });
  });

  group('EditImageTool', () {
    EditImageTool makeTool() =>
        EditImageTool(imageEditService: ImageEditService(tempDir: tempDir));

    test('buildSchema returns a function schema listing every action', () {
      final tool = makeTool();
      final schema = tool.buildSchema();
      expect(schema['type'], 'function');
      final fn = schema['function'] as Map<String, dynamic>;
      expect(fn['name'], 'edit_image');
      final params = fn['parameters'] as Map<String, dynamic>;
      final props = params['properties'] as Map<String, dynamic>;
      expect(props['action'], isNotNull);
      expect((props['action'] as Map)['enum'], [
        'compress',
        'crop',
        'resize',
        'rotate',
        'convert',
        'circle',
        'rounded_corners',
        'flip',
      ]);
      expect((params['required'] as List).contains('image_path'), isTrue);
      expect((params['required'] as List).contains('action'), isTrue);
    });

    test('execute throws when image_path is empty', () async {
      final tool = makeTool();
      final fakeService = _FakeToolService();
      expect(
        () => tool.execute({'action': 'crop'}, fakeService),
        throwsA(isA<ToolException>()),
      );
    });

    test('execute throws on unknown action', () async {
      final tool = makeTool();
      final fakeService = _FakeToolService();
      expect(
        () => tool.execute({
          'action': 'wat',
          'image_path': '/tmp/x.jpg',
        }, fakeService),
        throwsA(isA<ToolException>()),
      );
    });

    test(
      'execute runs compress end-to-end and returns a parseable envelope',
      () async {
        final tool = makeTool();
        final result = await tool.execute({
          'action': 'compress',
          'image_path': sourceJpeg.path,
          'quality': 50,
        }, _FakeToolService());
        final decoded = jsonDecode(result) as Map<String, dynamic>;
        expect(decoded['ok'], isTrue);
        expect(decoded['action'], 'compress');
        expect(decoded['format'], 'jpeg');
        expect(decoded['width'], 800);
        expect(decoded['height'], 600);
        expect(decoded['path'], isA<String>());
        expect(File(decoded['path'] as String).existsSync(), isTrue);
        expect(decoded['source_size'], greaterThan(decoded['size']));
      },
    );

    test(
      'execute runs crop with rect args and reports new dimensions',
      () async {
        final tool = makeTool();
        final result = await tool.execute({
          'action': 'crop',
          'image_path': sourceJpeg.path,
          'x': 50,
          'y': 50,
          'width': 200,
          'height': 150,
        }, _FakeToolService());
        final decoded = jsonDecode(result) as Map<String, dynamic>;
        expect(decoded['ok'], isTrue);
        expect(decoded['width'], 200);
        expect(decoded['height'], 150);
      },
    );

    test(
      'convert PNG → JPEG: writes a .jpg file with the right format',
      () async {
        final tool = makeTool();
        final result = await tool.execute({
          'action': 'convert',
          'image_path': sourcePng.path,
          'target_format': 'jpg',
          'quality': 90,
        }, _FakeToolService());
        final decoded = jsonDecode(result) as Map<String, dynamic>;
        expect(decoded['ok'], isTrue);
        expect(decoded['action'], 'convert');
        expect(decoded['format'], 'jpeg');
        expect(decoded['filename'], endsWith('.jpg'));
        expect(File(decoded['path'] as String).existsSync(), isTrue);
      },
    );

    test('convert PNG → WebP: writes a .webp file', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'convert',
        'image_path': sourcePng.path,
        'target_format': 'webp',
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['format'], 'webp');
      expect(decoded['filename'], endsWith('.webp'));
      expect(File(decoded['path'] as String).existsSync(), isTrue);
    });

    test('convert accepts the jpg alias for jpeg', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'convert',
        'image_path': sourcePng.path,
        'target_format': 'jpg',
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['format'], 'jpeg');
    });

    test('convert throws on an unsupported target_format', () async {
      final tool = makeTool();
      expect(
        () => tool.execute({
          'action': 'convert',
          'image_path': sourcePng.path,
          'target_format': 'xyz',
        }, _FakeToolService()),
        throwsA(isA<ToolException>()),
      );
    });

    test('convert without target_format keeps the source format', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'convert',
        'image_path': sourcePng.path,
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      // PNG → PNG (re-encoded losslessly).
      expect(decoded['format'], 'png');
      expect(decoded['filename'], endsWith('.png'));
    });

    test('buildSchema enum now includes convert', () {
      final tool = makeTool();
      final schema = tool.buildSchema();
      final actionProp =
          (schema['function']['parameters']['properties']
                  as Map<String, dynamic>)['action']
              as Map<String, dynamic>;
      expect(actionProp['enum'], [
        'compress',
        'crop',
        'resize',
        'rotate',
        'convert',
        'circle',
        'rounded_corners',
        'flip',
      ]);
    });

    test('circle end-to-end: returns a parseable envelope', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'circle',
        'image_path': sourcePng.path,
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      expect(decoded['action'], 'circle');
      expect(decoded['width'], decoded['height']);
      expect(File(decoded['path'] as String).existsSync(), isTrue);
    });

    test('rounded_corners end-to-end: returns a parseable envelope', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'rounded_corners',
        'image_path': sourcePng.path,
        'radius_percent': 8,
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      // The action string on the envelope is the camelCase enum
      // name (matches the rest of the actions' shape; the tool
      // accepts the snake_case alias on the way in).
      expect(decoded['action'], 'roundedCorners');
      expect(decoded['width'], 800);
      expect(decoded['height'], 600);
    });

    test('flip end-to-end: returns a parseable envelope', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'flip',
        'image_path': sourcePng.path,
        'direction': 'horizontal',
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      expect(decoded['action'], 'flip');
      expect(decoded['width'], 800);
      expect(decoded['height'], 600);
    });

    test('flip end-to-end: parses the snake_case action too', () async {
      final tool = makeTool();
      final result = await tool.execute({
        'action': 'flip',
        'image_path': sourcePng.path,
        'direction': 'vertical',
      }, _FakeToolService());
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['action'], 'flip');
    });
  });

  group('ChatProvider._augmentContentWithImagePaths', () {
    test('returns the original content unchanged when no images', () {
      final out = ChatProvider.augmentContentWithImagePaths('hello', const []);
      expect(out, 'hello');
    });

    test('appends a path list when images are present', () {
      final out = ChatProvider.augmentContentWithImagePaths('summarize this', [
        '/tmp/a.jpg',
        '/tmp/b.png',
      ]);
      expect(out, contains('summarize this'));
      expect(out, contains('Attached images'));
      expect(out, contains('- /tmp/a.jpg'));
      expect(out, contains('- /tmp/b.png'));
    });

    test('returns just the path list when content is empty', () {
      final out = ChatProvider.augmentContentWithImagePaths('', ['/tmp/a.jpg']);
      expect(out.startsWith('Attached images'), isTrue);
      expect(out, contains('- /tmp/a.jpg'));
    });
  });
}

/// We don't pass a real `ToolService` to the tool in tests —
/// the tool never reaches into it for `edit_image` (no
/// HTTP/MCP/sheets deps), so a stub is enough to satisfy the
/// signature without spinning up the full service graph.
class _FakeToolService implements ToolService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      '_FakeToolService: unexpected method call ${invocation.memberName}',
    );
  }
}
