import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

// The ask_user question + options card is a private widget
// (`_AskUserQuestionCard`). We exercise it via the public
// `MessageBubble`, exactly the path the chat list takes, and
// mount a real (but uninitialized) `ChatProvider` so the
// `context.read<ChatProvider>()` call inside `_buildAskUserQuestions`
// resolves without falling back to its "no provider" branch.
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:provider/provider.dart';

void main() {
  // Builds a chat message that has one ask_user tool call with
  // its question + options populated (the state the model sets
  // via ChatProvider._onToolCall after parsing the tool args).
  ChatMessage _assistantWithAskUser({
    String question = 'Which option do you prefer?',
    List<String> options = const ['Option A', 'Option B', 'Option C'],
  }) {
    final tc = ToolCall(
      id: 'tc_ask',
      name: 'ask_user',
      arguments: '{}',
      status: ToolCallStatus.running,
      question: question,
      options: options,
    );
    return ChatMessage(
      id: 'm_ask',
      role: MessageRole.assistant,
      content: 'I need to check something with you first.',
      toolCalls: [tc],
    );
  }

  Future<void> pumpWithProvider(
    WidgetTester tester,
    ChatMessage message, {
    required ChatProvider provider,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        home: ChangeNotifierProvider<ChatProvider>.value(
          value: provider,
          child: Scaffold(
            body: MessageBubble(message: message, onCopy: (_) {}),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // We never call any provider methods, so an empty subclass
  // is enough to satisfy the type lookup. Casting via
  // `dynamic` keeps the test independent of the constructor's
  // eight required service collaborators.
  ChatProvider _emptyProvider() {
    // ignore: invalid_use_of_internal_member
    return _NoopChatProviderShim();
  }

  group('ask_user question card placement', () {
    testWidgets('renders the question + options BELOW the bubble content '
        '(not inside the tool call section)', (tester) async {
      final m = _assistantWithAskUser(
        question: 'Which option do you prefer?',
        options: ['Option A', 'Option B', 'Option C'],
      );
      await pumpWithProvider(tester, m, provider: _emptyProvider());

      // The question text shows up.
      expect(find.text('Which option do you prefer?'), findsOneWidget);
      // Every option shows up as a chip.
      expect(find.text('Option A'), findsOneWidget);
      expect(find.text('Option B'), findsOneWidget);
      expect(find.text('Option C'), findsOneWidget);
      // The "Model asks:" header is the new affordance that
      // distinguishes this card from a generic content block.
      expect(find.text('Model asks:'), findsOneWidget);

      // Layout sanity: the question card sits *after* the
      // assistant bubble content in the Column. We assert this
      // by walking the Column's children and confirming the
      // question card is the last rendered child. Reading the
      // y-coordinate via `getCenter` is more robust against
      // small layout tweaks than pinning pixel positions.
      final contentCenter = tester.getCenter(
        find.text('I need to check something with you first.'),
      );
      final questionCenter = tester.getCenter(
        find.text('Which option do you prefer?'),
      );
      expect(
        questionCenter.dy > contentCenter.dy,
        isTrue,
        reason: 'question card should be rendered below the bubble content',
      );
    });

    testWidgets('renders NOTHING extra when no ask_user tool call is present', (
      tester,
    ) async {
      // An assistant message without any tool calls — used to
      // be the default state for every turn before ask_user
      // landed. The question card must stay out of the way.
      final m = ChatMessage(
        id: 'm_plain',
        role: MessageRole.assistant,
        content: 'Just a plain reply, no questions.',
      );
      await pumpWithProvider(tester, m, provider: _emptyProvider());

      expect(find.text('Model asks:'), findsNothing);
      expect(find.text('Which option do you prefer?'), findsNothing);
    });

    testWidgets('shows the Chinese prompt header under the zh locale', (
      tester,
    ) async {
      final m = _assistantWithAskUser();
      await pumpWithProvider(
        tester,
        m,
        provider: _emptyProvider(),
        locale: const Locale('zh'),
      );
      expect(find.text('模型询问:'), findsOneWidget);
    });
  });
}

/// Tiny stand-in for ChatProvider that does nothing in the
/// constructor and never calls its 8 required collaborators.
/// We cast through `dynamic` to bypass the heavy constructor
/// while still satisfying `context.read<ChatProvider>()`'s
/// type lookup.
class _NoopChatProviderShim extends ChangeNotifier implements ChatProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
