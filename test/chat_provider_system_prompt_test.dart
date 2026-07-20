import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildBaseSystemPrompt', () {
    test(
      'returns the short system prompt that points at load_tool (no tool_usage skill)',
      () {
        // The whole point of the refactor: the always-on system prompt
        // must be small enough to leave room for a 4K-context local
        // model. Per-tool docs now live in each tool's
        // `compactSchemaForModel` (returned by `load_tool`), not in
        // the system prompt and not in any skill.
        final prompt = buildBaseSystemPrompt();

        // Hard size cap. ~600 chars ≈ 200 tokens for a Chinese
        // tokenizer, leaving the rest of a 4K context for the
        // user's messages. The cap was bumped to ~1500 to fit the
        // chat-attachment-path cross-cutting rule, which is the
        // one rule that genuinely needs to be in every turn (it
        // affects every chat input). If a future edit accidentally
        // re-inlines any per-tool docs, this test will fire.
        expect(
          prompt.length,
          lessThan(1500),
          reason:
              'base system prompt must stay small; per-tool docs belong in '
              'the tool compactSchemaForModel, not inline',
        );

        // The pointer to load_tool must survive.
        expect(prompt, contains('load_tool'));
        // No more tool_usage skill reference.
        expect(prompt, isNot(contains('工具使用提示')));
      },
    );

    test('does not inline per-tool reminders anymore', () {
      // Regression guard: the previous prompt literally contained
      // hundreds of chars of fetch_web / file / timer / google_sheet
      // best-practice docs. A small local model with a 4K context
      // window would burn through those before seeing the user's
      // first message. If a future edit re-inlines any of them
      // (a "I'll just add this one tip" temptation), this test
      // fires.
      final prompt = buildBaseSystemPrompt();

      for (final fragment in const [
        'link_text 只返回链接 URL',
        'action=edit',
        'global_replace=true',
        'delay_seconds',
        'create_tab',
        'batchUpdate: addSheet',
        'userinfo.email',
        'ip-api.com',
        'EventKit',
        'SAF',
        'XDG',
      ]) {
        expect(
          prompt,
          isNot(contains(fragment)),
          reason:
              'fragment "$fragment" is a per-tool doc that must live in '
              'the tool compactSchemaForModel, not in the always-on system prompt',
        );
      }
    });

    test('mentions the working directory when one is configured', () {
      final prompt = buildBaseSystemPrompt(workingDirectory: '/Users/me/code');
      expect(prompt, contains('/Users/me/code'));
      expect(prompt, contains('默认工作目录'));
    });

    test('omits the working directory hint when none is set', () {
      final prompt = buildBaseSystemPrompt();
      expect(prompt, isNot(contains('默认工作目录')));
    });

    test(
      'includes the MCP load_tool pointer when at least one server is enabled',
      () {
        final nonePrompt = buildBaseSystemPrompt(enabledMcpServerCount: 0);
        expect(nonePrompt, isNot(contains('MCP 工具')));

        final withOne = buildBaseSystemPrompt(enabledMcpServerCount: 1);
        expect(withOne, contains('1 个 MCP 服务器'));
        expect(withOne, contains('mcp__'));

        final withSeveral = buildBaseSystemPrompt(enabledMcpServerCount: 5);
        expect(withSeveral, contains('5 个 MCP 服务器'));
      },
    );

    test('always carries the chat-attachment cross-cutting rule', () {
      // The desktop-vs-mobile path distinction for chat attachments
      // is the one cross-tool rule the model needs every turn (it
      // affects every chat input, not a specific tool). It MUST
      // survive even when no tools are loaded yet.
      final prompt = buildBaseSystemPrompt();
      expect(prompt, contains('聊天附件'));
      expect(prompt, contains('桌面端'));
      expect(prompt, contains('手机端'));
      expect(prompt, contains('picker://'));
    });
  });
}
