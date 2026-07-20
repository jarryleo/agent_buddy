import 'package:agent_buddy/models/file_type.dart';
import 'package:agent_buddy/models/provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelProvider.supportedFileTypes', () {
    ModelProvider baseProvider({Set<AgentFileType>? types}) {
      return ModelProvider(
        id: 'p1',
        name: 'Test',
        protocol: ProviderProtocol.openai,
        baseUrl: 'https://example.com',
        apiKey: 'k',
        chatPath: ProviderProtocol.openai.defaultPath,
        supportedFileTypes: types,
      );
    }

    test('defaults to text + image when nothing is configured', () {
      // `text` is pinned on (settings UI renders it as a disabled,
      // always-checked chip) but doesn't actually gate wire
      // behaviour — it's there so the persisted JSON records
      // "yes, text files are part of the supported set" without
      // claiming an inline capability the implementation doesn't
      // actually have.
      final p = baseProvider();
      expect(p.supportedFileTypes, isNull);
      expect(
        p.effectiveSupportedFileTypes,
        equals({AgentFileType.text, AgentFileType.image}),
      );
    });

    test('returns the configured set when present', () {
      final p = baseProvider(types: {AgentFileType.image, AgentFileType.text});
      expect(
        p.supportedFileTypes,
        equals({AgentFileType.image, AgentFileType.text}),
      );
      expect(
        p.effectiveSupportedFileTypes,
        equals({AgentFileType.image, AgentFileType.text}),
      );
    });

    test('preserves an explicit empty set (no categories enabled)', () {
      // Empty set != null. The user has explicitly disabled every
      // category; we must not silently fall back to image.
      final p = baseProvider(types: <AgentFileType>{});
      expect(p.supportedFileTypes, isEmpty);
      expect(p.effectiveSupportedFileTypes, isEmpty);
    });

    test('round-trips through toJson / fromJson', () {
      final p = baseProvider(
        types: {
          AgentFileType.image,
          AgentFileType.audio,
          AgentFileType.document,
        },
      );
      final raw = p.toRawJson();
      final restored = ModelProvider.fromRawJson(raw);
      expect(restored.supportedFileTypes, equals(p.supportedFileTypes));
    });

    test('fromJson falls back to text + image when the field is absent', () {
      // Older persisted rows don't have the key at all.
      final json = {
        'id': 'p1',
        'name': 'Test',
        'protocol': 'openai',
        'baseUrl': 'https://example.com',
        'apiKey': 'k',
        'chatPath': '/v1/chat/completions',
        'createdAt': '2025-01-01T00:00:00.000Z',
      };
      final p = ModelProvider.fromJson(json);
      expect(p.supportedFileTypes, isNull);
      expect(
        p.effectiveSupportedFileTypes,
        equals({AgentFileType.text, AgentFileType.image}),
      );
    });

    test('fromJson preserves an explicit empty set', () {
      final json = {
        'id': 'p1',
        'name': 'Test',
        'protocol': 'openai',
        'baseUrl': 'https://example.com',
        'apiKey': 'k',
        'chatPath': '/v1/chat/completions',
        'createdAt': '2025-01-01T00:00:00.000Z',
        'supportedFileTypes': <String>[],
      };
      final p = ModelProvider.fromJson(json);
      expect(p.supportedFileTypes, isEmpty);
      expect(p.effectiveSupportedFileTypes, isEmpty);
    });

    test('fromJson drops unknown enum names silently', () {
      // Forward compatibility: an older client adds a category the
      // current build doesn't know about. We must not crash; we
      // just ignore the unknown value.
      final json = {
        'id': 'p1',
        'name': 'Test',
        'protocol': 'openai',
        'baseUrl': 'https://example.com',
        'apiKey': 'k',
        'chatPath': '/v1/chat/completions',
        'createdAt': '2025-01-01T00:00:00.000Z',
        'supportedFileTypes': <String>['image', 'spreadsheet', 'document'],
      };
      final p = ModelProvider.fromJson(json);
      expect(
        p.supportedFileTypes,
        equals({AgentFileType.image, AgentFileType.document}),
      );
    });

    test('copyWith preserves the set when not specified', () {
      final p = baseProvider(types: {AgentFileType.image, AgentFileType.text});
      final renamed = p.copyWith(name: 'Renamed');
      expect(renamed.name, 'Renamed');
      expect(
        renamed.supportedFileTypes,
        equals({AgentFileType.image, AgentFileType.text}),
      );
    });

    test('copyWith can clear the set via an explicit empty', () {
      final p = baseProvider(types: {AgentFileType.image});
      final cleared = p.copyWith(supportedFileTypes: <AgentFileType>{});
      expect(cleared.supportedFileTypes, isEmpty);
      expect(cleared.effectiveSupportedFileTypes, isEmpty);
    });
  });
}
