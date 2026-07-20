import 'package:agent_buddy/models/mcp_provider.dart';
import 'package:agent_buddy/services/tools/tool_base.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure unit tests for the new `load_tool` mechanism. The heavy
/// integration test (full ChatProvider + Hive + transport mocks)
/// lives next to it; this file pins down the per-tool properties
/// the lazy-loading layer relies on.
void main() {
  group('ToolBase.shortDescription', () {
    test('defaults to the first line of description', () {
      final t = _FakeTool(
        id: 'fake',
        description: 'first line\nsecond line\nthird',
      );
      expect(t.shortDescription, 'first line');
    });

    test('honors an explicit shortDescription override', () {
      final t = _FakeTool(
        id: 'fake',
        description: 'long description goes here',
        shortDescription: 'short',
      );
      expect(t.shortDescription, 'short');
    });

    test('strips trailing whitespace', () {
      final t = _FakeTool(id: 'fake', description: 'trim me   \nnext');
      expect(t.shortDescription, 'trim me');
    });
  });

  group('ToolBase.compactSchemaForModel', () {
    test('falls back to pretty JSON when no override is provided', () {
      final t = _FakeTool(
        id: 'fake',
        description: 'd',
        schema: {
          'type': 'function',
          'function': {
            'name': 'fake',
            'description': 'd',
            'parameters': {
              'type': 'object',
              'properties': {
                'x': {'type': 'string'},
              },
            },
          },
        },
      );
      final compact = t.compactSchemaForModel;
      expect(compact, contains('"function"'));
      expect(compact, contains('"name"'));
      expect(compact, contains('"fake"'));
      // pretty JSON uses 2-space indent
      expect(compact, contains('  "name"'));
    });

    test('honors explicit compactSchemaForModel override', () {
      final t = _FakeTool(
        id: 'fake',
        description: 'd',
        compact: 'manual cheat-sheet',
      );
      expect(t.compactSchemaForModel, 'manual cheat-sheet');
    });

    test('returns empty string when buildSchema returns empty map', () {
      final t = _FakeTool(id: 'fake', description: 'd', schema: const {});
      expect(t.compactSchemaForModel, '');
    });
  });

  group('every registry tool has a non-empty shortDescription', () {
    // Sanity guard: the always-on "tool index" would silently
    // skip tools whose shortDescription is empty, defeating the
    // whole point of the lazy-load design. If a future tool
    // forgets to provide one, this test fires.
    test('all built-in tools expose a one-liner', () {
      for (final tool in ToolRegistry.all) {
        expect(
          tool.shortDescription,
          isNotEmpty,
          reason:
              'tool "${tool.id}" must define shortDescription for the index',
        );
        expect(
          tool.shortDescription.length,
          lessThanOrEqualTo(60),
          reason:
              'tool "${tool.id}" shortDescription should fit in the index '
              '(≤60 chars)',
        );
      }
    });

    test('all built-in tools except load_tool/load_skill/call_mcp '
        'expose a compactSchemaForModel that mentions the tool id', () {
      // The compact cheat-sheet is what the model sees on
      // `load_tool`. Every tool whose schema is being lazy-loaded
      // should have a manual override (the default pretty JSON
      // fallback is huge for the big tools).
      final exempt = {'load_tool', 'load_skill', 'call_mcp'};
      for (final tool in ToolRegistry.all) {
        if (exempt.contains(tool.id)) continue;
        if (!tool.isSupportedOnCurrentPlatform) continue;
        final compact = tool.compactSchemaForModel;
        expect(
          compact,
          isNotEmpty,
          reason:
              'tool "${tool.id}" must override compactSchemaForModel '
              'so the load_tool result stays compact',
        );
      }
    });
  });

  group('MCP provider shape', () {
    test('round-trips through toJson/fromJson', () {
      final p = McpProvider(
        id: 'm1',
        name: 'demo',
        jsonConfig: '{"url":"http://x"}',
        enabled: true,
        createdAt: DateTime(2026, 1, 1),
      );
      final back = McpProvider.fromJson(p.toJson());
      expect(back.id, 'm1');
      expect(back.name, 'demo');
      expect(back.enabled, isTrue);
      expect(back.jsonConfig, '{"url":"http://x"}');
    });
  });
}

class _FakeTool extends ToolBase {
  _FakeTool({
    required this.id,
    required this.description,
    String? shortDescription,
    this.compact,
    this.schema = const {
      'type': 'function',
      'function': {'name': 'fake'},
    },
  }) : _short = shortDescription;

  @override
  final String id;
  @override
  final String description;
  final String? _short;
  @override
  String get shortDescription => _short ?? super.shortDescription;
  final String? compact;
  final Map<String, dynamic> schema;

  @override
  String get name => id;

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  String get compactSchemaForModel =>
      compact ?? (schema.isEmpty ? '' : super.compactSchemaForModel);

  @override
  Map<String, dynamic> buildSchema() => schema;

  @override
  Future<String> execute(Map<String, dynamic> args, dynamic services) async =>
      '';
}
