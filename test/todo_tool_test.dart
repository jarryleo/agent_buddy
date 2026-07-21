import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/todo_tool.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TodoTool', () {
    test('is registered under id "todo"', () {
      final tool = ToolRegistry.byId('todo');
      expect(tool, isA<TodoTool>());
    });

    test('is supported on every platform', () {
      final tool = TodoTool();
      expect(tool.isSupportedOnCurrentPlatform, isTrue);
      expect(tool.isEnabledByDefault, isTrue);
    });

    test('schema declares the canonical 9-action enum', () {
      final schema = TodoTool().buildSchema();
      final actions =
          (schema['function']['parameters']['properties']['action']
                  ['enum'] as List)
              .cast<String>();
      expect(actions, [
        'create',
        'add',
        'complete',
        'update',
        'remove',
        'list',
        'get',
        'clear',
        'abandon',
      ]);
    });

    test('schema marks action as the only required parameter', () {
      final schema = TodoTool().buildSchema();
      final required =
          (schema['function']['parameters']['required'] as List).cast<String>();
      expect(required, ['action']);
    });

    test('compactSchemaForModel mentions the supervision prompt behavior',
        () {
      final cheat = TodoTool().compactSchemaForModel;
      expect(cheat, contains('create'));
      expect(cheat, contains('add'));
      expect(cheat, contains('complete'));
      expect(cheat, contains('clear'));
      expect(cheat, contains('abandon'));
    });

    test('execute() throws — the tool is a thin schema shim', () async {
      final tool = TodoTool();
      // Even though the dispatcher never reaches execute(), a
      // direct call must fail loudly rather than silently
      // no-op so future refactors don't accidentally route
      // through the wrong path.
      final stubServices = ToolService();
      expect(
        () => tool.execute({'action': 'list'}, stubServices),
        throwsA(isA<Exception>()),
      );
    });

    test('runAction routes the args through the provided handler', () async {
      var received = const <String, dynamic>{};
      final result = await TodoTool.runAction(
        {'action': 'add', 'content': 'x'},
        (args) async {
          received = args;
          return '{"ok":true}';
        },
      );
      expect(result, '{"ok":true}');
      expect(received['action'], 'add');
      expect(received['content'], 'x');
    });
  });
}