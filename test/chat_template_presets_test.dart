import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_buddy/models/builtin_model.dart';
import 'package:agent_buddy/services/chat_template_presets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper that wires up a mock `rootBundle` response keyed by
/// asset path. Returns the path-to-source map for assertions.
void _mockAssetBundle(Map<String, String> sources) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
        final key = utf8.decode(message!.buffer.asUint8List());
        final src = sources[key];
        if (src == null) return null;
        return ByteData.view(Uint8List.fromList(utf8.encode(src)).buffer);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatTemplatePresets.keys', () {
    test('exposes the three built-in keys in a stable order', () {
      // Stable order drives the chip rendering order in the form.
      // If a future PR reorders the map, the UI changes — that's
      // intentional but worth locking in via a test so the change
      // is visible at review time.
      expect(
        ChatTemplatePresets.keys,
        equals(<String>['qwen', 'gemma', 'minicpm5']),
      );
    });

    test('isPresetKey recognizes only the three keys', () {
      expect(ChatTemplatePresets.isPresetKey('qwen'), isTrue);
      expect(ChatTemplatePresets.isPresetKey('gemma'), isTrue);
      expect(ChatTemplatePresets.isPresetKey('minicpm5'), isTrue);
      expect(ChatTemplatePresets.isPresetKey('llama3'), isFalse);
      expect(ChatTemplatePresets.isPresetKey(''), isFalse);
    });

    test('labelOf falls back to the key for unknown ids', () {
      // Defensive — the chips are rendered from `keys`, so this
      // only matters if a future caller passes a stale id from
      // persisted state. Returning the key itself keeps the UI
      // honest instead of crashing.
      expect(ChatTemplatePresets.labelOf('qwen'), 'qwen');
      expect(ChatTemplatePresets.labelOf('gemma'), 'gemma');
      expect(ChatTemplatePresets.labelOf('minicpm5'), 'minicpm5');
      expect(ChatTemplatePresets.labelOf('mystery'), 'mystery');
    });

    test('assetPathFor returns a non-empty path for every preset', () {
      for (final k in ChatTemplatePresets.keys) {
        final path = ChatTemplatePresets.assetPathFor(k);
        expect(path, isNotNull, reason: '$k must have an asset path');
        expect(path, startsWith('assets/jinja/'));
        expect(path, endsWith('.jinja'));
      }
    });

    test('assetPathFor returns null for unknown ids', () {
      expect(ChatTemplatePresets.assetPathFor('llama3'), isNull);
    });
  });

  group('ChatTemplatePresets.presetKeyForBuiltin', () {
    test('maps Qwen family ids to qwen', () {
      // Substring match — a new built-in card like
      // "qwen3.5-0.8b-q4_k_m" should auto-fill without us
      // having to maintain an explicit table.
      expect(
        ChatTemplatePresets.presetKeyForBuiltin('qwen3.5-0.8b-q4_k_m'),
        'qwen',
      );
      expect(
        ChatTemplatePresets.presetKeyForBuiltin('qwen2.5-7b-instruct'),
        'qwen',
      );
    });

    test('maps Gemma family ids to gemma', () {
      expect(
        ChatTemplatePresets.presetKeyForBuiltin('gemma-4-e2b-it-qat-q4_0'),
        'gemma',
      );
      expect(ChatTemplatePresets.presetKeyForBuiltin('gemma-2-9b-it'), 'gemma');
    });

    test('maps MiniCPM family ids (with dash variants) to minicpm5', () {
      expect(
        ChatTemplatePresets.presetKeyForBuiltin('minicpm-v-2_6'),
        'minicpm5',
      );
      expect(
        ChatTemplatePresets.presetKeyForBuiltin('MiniCPM3-4B'),
        'minicpm5',
      );
      expect(
        ChatTemplatePresets.presetKeyForBuiltin('mini-cpm-3-4b'),
        'minicpm5',
      );
    });

    test('returns null for unknown families', () {
      expect(ChatTemplatePresets.presetKeyForBuiltin('llama3-8b'), isNull);
      expect(ChatTemplatePresets.presetKeyForBuiltin('mistral-7b'), isNull);
      expect(ChatTemplatePresets.presetKeyForBuiltin(''), isNull);
    });

    test('matches case-insensitively', () {
      // Built-in ids are stored lowercase in practice but we
      // shouldn't be brittle about it.
      expect(ChatTemplatePresets.presetKeyForBuiltin('QWEN3-8B'), 'qwen');
      expect(ChatTemplatePresets.presetKeyForBuiltin('Gemma-2-9B'), 'gemma');
    });

    test('presetKeyForBuiltinModel handles null', () {
      expect(ChatTemplatePresets.presetKeyForBuiltinModel(null), isNull);
    });

    test('presetKeyForBuiltinModel dispatches via BuiltinModel.id', () {
      const qwen = BuiltinModel(
        id: 'qwen3.5-0.8b-q4_k_m',
        displayName: 'Qwen3.5-0.8B',
        description: 'tiny',
        modelUrl: 'https://example/qwen.gguf',
        modelFilename: 'qwen.gguf',
      );
      const gemma = BuiltinModel(
        id: 'gemma-4-e2b-it-qat-q4_0',
        displayName: 'Gemma-4',
        description: 'tiny',
        modelUrl: 'https://example/gemma.gguf',
        modelFilename: 'gemma.gguf',
      );
      expect(ChatTemplatePresets.presetKeyForBuiltinModel(qwen), 'qwen');
      expect(ChatTemplatePresets.presetKeyForBuiltinModel(gemma), 'gemma');
    });
  });

  group('ChatTemplatePresets.load', () {
    test('returns null for an unknown preset key', () async {
      final result = await ChatTemplatePresets.load('llama3');
      expect(result, isNull);
    });

    test('returns the bundled Jinja for a known preset key', () async {
      // Mock the asset bundle to return a stable payload per
      // preset so we don't have to ship the real .jinja files in
      // the unit test environment. We're testing the
      // asset-path resolution + bytes→string path, not the
      // contents of the bundled templates themselves.
      const qwenSource = '{% for m in messages %}{{ m }}';
      const gemmaSource = '<start_of_turn>user\n{{ content }}';
      const minicpmSource = '<|im_start|>user\n{{ content }}';

      _mockAssetBundle({
        'assets/jinja/chat_template_qwen.jinja': qwenSource,
        'assets/jinja/chat_template_gemma.jinja': gemmaSource,
        'assets/jinja/chat_template_minicpm5.jinja': minicpmSource,
      });

      expect(await ChatTemplatePresets.load('qwen'), qwenSource);
      expect(await ChatTemplatePresets.load('gemma'), gemmaSource);
      expect(await ChatTemplatePresets.load('minicpm5'), minicpmSource);
    });
  });
}
