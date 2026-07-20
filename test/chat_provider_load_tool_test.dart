import 'dart:io';

import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/providers/settings_provider.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/chat_session_repository.dart';
import 'package:agent_buddy/services/download_service.dart';
import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/services/local_llm_service.dart';
import 'package:agent_buddy/services/storage_service.dart';
import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Integration test for the `load_tool` lazy-loading layer.
///
/// Sets up a real ChatProvider (Hive + SharedPreferences + the
/// standard service graph) so we can poke at
/// `_buildToolsSchema` and `_loadTool` end-to-end without
/// spinning up the full streaming pipeline. The point of these
/// tests is to lock the public-facing invariants — load_tool is
/// always present, built-in schemas are gated by `_loadedToolIds`,
/// session lifecycle clears the loaded set — so a future refactor
/// can't silently regress the token savings.
void main() {
  late Directory tempDir;
  late StorageService storage;
  late SettingsProvider settings;
  late ToolService tools;
  late ChatProvider chat;

  setUpAll(() {
    ChatSessionRepository.registerAdapters();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp(
      'agent_buddy_load_tool_it_',
    );
    Hive.init(tempDir.path);
    storage = StorageService();
    await storage.init();
    settings = SettingsProvider(storage);
    await settings.load();
    tools = ToolService(storage: storage);
    chat = ChatProvider(
      storage,
      ApiService(),
      tools,
      ImageService(),
      LocalLlmService(),
      settings,
      DownloadService(),
      FileAttachmentService(),
    );
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(ChatSessionRepository.boxName);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('ChatProvider._buildToolsSchema — lazy loading', () {
    test('emits only entry-point tools when nothing is loaded', () async {
      final schemas = await chat.debugBuildToolsSchema();
      // No tool was loaded yet — only the always-on entry points
      // (load_tool, plus load_skill when skills are active) should
      // be in the wire array. This is the whole point of the
      // refactor: a fresh conversation pays zero per-tool-schema
      // tokens.
      final names = schemas
          .map((s) => s['function']?['name'] as String?)
          .whereType<String>()
          .toSet();
      expect(names, contains('load_tool'));
      // No built-in execution tool should be present until loaded.
      for (final blocked in ['fetch_web', 'memory', 'current_time', 'file']) {
        expect(
          names,
          isNot(contains(blocked)),
          reason:
              '$blocked must not appear until the model loads it via load_tool',
        );
      }
    });

    test(
      'the load_tool enum hint lists every active built-in tool id',
      () async {
        final schemas = await chat.debugBuildToolsSchema();
        final loadToolSchema = schemas.firstWhere(
          (s) => s['function']?['name'] == 'load_tool',
          orElse: () => throw StateError('load_tool not in schema list'),
        );
        final enumList =
            (loadToolSchema['function']?['parameters']?['properties']
                    as Map?)?['tool_names']?['items']?['enum']
                as List?;
        expect(enumList, isNotNull);
        expect(enumList, isNotEmpty);
        // Self-reference must be excluded.
        expect(enumList, isNot(contains('load_tool')));
        // Core tools should all be present.
        expect(enumList, containsAll(['fetch_web', 'current_time', 'memory']));
      },
    );

    test('loading a tool adds its schema to the wire array', () async {
      await chat.debugLoadTool('fetch_web');
      final schemas = await chat.debugBuildToolsSchema();
      final names = schemas
          .map((s) => s['function']?['name'] as String?)
          .whereType<String>()
          .toSet();
      expect(names, containsAll({'load_tool', 'fetch_web'}));
      // Other tools still absent.
      expect(names, isNot(contains('current_time')));
    });

    test('loadTool is idempotent — second call returns the manual without'
        ' re-adding the schema', () async {
      await chat.debugLoadTool('current_time');
      final first = await chat.debugBuildToolsSchema();
      await chat.debugLoadTool('current_time');
      final second = await chat.debugBuildToolsSchema();
      expect(first.length, second.length);
      // current_time appears exactly once across both.
      final names = second
          .map((s) => s['function']?['name'] as String?)
          .whereType<String>()
          .where((n) => n == 'current_time')
          .toList();
      expect(names, hasLength(1));
    });

    test('throws ToolException for an unknown tool name', () async {
      expect(
        () => chat.debugLoadTool('not_a_real_tool'),
        throwsA(isA<ToolException>()),
      );
    });

    test('batch loading returns combined manuals in one response', () async {
      final response = await chat.debugLoadTools([
        'fetch_web',
        'memory',
        'current_time',
      ]);
      // All three manuals land in the same response.
      expect(response, contains('## fetch_web'));
      expect(response, contains('## memory'));
      expect(response, contains('## current_time'));
      // The response is bounded by the loaded set summary.
      expect(response, contains('本批'));
    });

    test('a single batch call adds all three to the loaded set in one '
        'round-trip', () async {
      // One call should be enough — same effect as three
      // sequential debugLoadTool calls.
      await chat.debugLoadTools(['fetch_web', 'memory', 'current_time']);
      expect(
        chat.loadedToolIds,
        containsAll({'fetch_web', 'memory', 'current_time'}),
      );
      final schemas = await chat.debugBuildToolsSchema();
      final names = schemas
          .map((s) => s['function']?['name'] as String?)
          .whereType<String>()
          .toSet();
      expect(
        names,
        containsAll({'load_tool', 'fetch_web', 'memory', 'current_time'}),
      );
    });

    test(
      'partial failure surfaces in a footer but still loads the rest',
      () async {
        final response = await chat.debugLoadTools([
          'fetch_web',
          'not_a_real_tool',
          'memory',
        ]);
        // The good ones made it in.
        expect(response, contains('## fetch_web'));
        expect(response, contains('## memory'));
        // The bad one is named in the failure footer.
        expect(response, contains('加载失败'));
        expect(response, contains('not_a_real_tool'));
        // And the loaded set still got the good ones.
        expect(chat.loadedToolIds, containsAll({'fetch_web', 'memory'}));
        expect(chat.loadedToolIds, isNot(contains('not_a_real_tool')));
      },
    );

    test('total failure throws ToolException (so the orchestrator '
        'surfaces it as a tool error)', () async {
      expect(
        () => chat.debugLoadTools(['unknown_a', 'unknown_b']),
        throwsA(
          isA<ToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('全部失败'),
              contains('unknown_a'),
              contains('unknown_b'),
            ),
          ),
        ),
      );
      // Nothing should have been added to the loaded set.
      expect(chat.loadedToolIds, isEmpty);
    });

    test('empty input throws a friendly ToolException', () async {
      expect(
        () => chat.debugLoadTools(const []),
        throwsA(isA<ToolException>()),
      );
    });

    test('legacy scalar tool_name no longer works (back-compat removed '
        'to push models toward batching)', () async {
      // The production schema no longer declares a `tool_name`
      // field. If a model still emits the old shape, the
      // resolver lands on the empty-list error path and the
      // loaded set stays empty — no surprise side effects.
      expect(
        () => chat.debugLoadToolRaw({'tool_name': 'fetch_web'}),
        throwsA(isA<ToolException>()),
      );
      expect(chat.loadedToolIds, isEmpty);
    });

    test('a single-element array is allowed but documented as wasteful '
        'in the system prompt', () async {
      // The schema accepts minItems=1 so a single id still works
      // (we'd rather load something than throw on edge cases),
      // but the model is steered toward batching.
      final response = await chat.debugLoadTools(['fetch_web']);
      expect(response, contains('## fetch_web'));
      expect(chat.loadedToolIds, contains('fetch_web'));
    });

    test('deduplicates when the same id appears multiple times', () async {
      final response = await chat.debugLoadTools([
        'fetch_web',
        'fetch_web',
        'memory',
        'memory',
      ]);
      // Only one manual per id should appear.
      expect('## fetch_web'.allMatches(response).length, 1);
      expect('## memory'.allMatches(response).length, 1);
      expect(chat.loadedToolIds, containsAll({'fetch_web', 'memory'}));
    });

    test('the loaded set survives across _buildToolsSchema calls', () async {
      await chat.debugLoadTool('memory');
      await chat.debugLoadTool('fetch_web');
      // Trigger another build to confirm set membership persists.
      final schemas = await chat.debugBuildToolsSchema();
      final names = schemas
          .map((s) => s['function']?['name'] as String?)
          .whereType<String>()
          .toSet();
      expect(names, containsAll({'load_tool', 'memory', 'fetch_web'}));
    });
  });

  group('session lifecycle', () {
    test('createNewSession clears the loaded set', () async {
      await chat.debugLoadTool('fetch_web');
      expect(chat.loadedToolIds, contains('fetch_web'));
      await chat.createNewSession();
      expect(chat.loadedToolIds, isEmpty);
      final schemas = await chat.debugBuildToolsSchema();
      final names = schemas
          .map((s) => s['function']?['name'] as String?)
          .whereType<String>()
          .toSet();
      // load_tool is always present; load_skill also stays when
      // the default skill set is active. The execution tools
      // (fetch_web / memory / etc.) must be gone.
      expect(names, contains('load_tool'));
      expect(names, isNot(contains('fetch_web')));
      expect(names, isNot(contains('memory')));
    });

    test('clearMessages clears the loaded set', () async {
      await chat.debugLoadTool('memory');
      await chat.clearMessages();
      expect(chat.loadedToolIds, isEmpty);
    });
  });

  group('canLoadTool', () {
    test('rejects load_tool itself', () {
      expect(chat.canLoadTool('load_tool'), isFalse);
    });

    test('rejects unknown ids', () {
      expect(chat.canLoadTool('not_a_real_tool'), isFalse);
    });

    test(
      'accepts a built-in tool id that the settings provider knows about',
      () {
        // memory is a default-on tool — should be loadable.
        expect(chat.canLoadTool('memory'), isTrue);
      },
    );
  });

  group('system prompt tool index', () {
    test('the always-on system prompt carries the tool index', () async {
      await chat.debugLoadTool('fetch_web');
      final prompts = chat.debugBuildSystemPrompts();
      // Look for the tool index block.
      expect(
        prompts.any((p) => p.contains('可用工具')),
        isTrue,
        reason: 'system prompt must include the tool index',
      );
      // The loaded set should be visible so the model knows what
      // it can call without re-loading.
      expect(prompts.any((p) => p.contains('fetch_web')), isTrue);
    });
  });

  group('registry invariants', () {
    test('LoadTool is registered exactly once', () {
      final matches = ToolRegistry.all.where((t) => t.id == 'load_tool');
      expect(matches, hasLength(1));
    });
  });
}
