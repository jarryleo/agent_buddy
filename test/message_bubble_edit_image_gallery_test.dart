import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/edited_image.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/providers/chat_provider.dart';
import 'package:agent_buddy/widgets/edit_image_card.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Regression tests for the "edited image result bubble is
/// invisible" bug.
///
/// Root cause: the home page collapses consecutive assistant
/// messages that are *tool-only* (have `toolCalls` but no
/// `content` / `thinking`) into a single `_GroupedToolCalls`
/// widget. Before the fix, that widget rendered only the
/// collapsed tool-call summary card and an expansion list of
/// per-tool `_ToolCallCard`s, never the `_buildEditedImagesGallery`
/// section that surfaces `edit_image` results. As a result, a
/// turn where the model called `edit_image` and then produced a
/// text reply left the user staring at a "Tool call summary"
/// card with no preview of the processed image.
///
/// The fix routes the edited-image gallery into
/// `_GroupedToolCalls` as a sibling of the summary card (always
/// visible, no expansion required) so the gallery is reachable
/// on the canonical rendering path for `edit_image` results.
void main() {
  ChatMessage _toolOnlyAssistantWithEditedImage({
    String toolId = 'tc_edit',
    EditedImage? editedImage,
  }) {
    final tc = ToolCall(
      id: toolId,
      name: 'edit_image',
      arguments: '{}',
      status: ToolCallStatus.success,
      result: '{}',
      editedImages: editedImage == null
          ? [
              EditedImage(
                path: 'C:/temp/edited.jpg',
                filename: 'edited.jpg',
                width: 800,
                height: 600,
                size: 409600,
                format: 'jpeg',
                action: 'compress',
                sourceWidth: 800,
                sourceHeight: 600,
                sourceSize: 819200,
              ),
            ]
          : [editedImage],
    );
    return ChatMessage(
      id: 'm_edit',
      role: MessageRole.assistant,
      // No content, no thinking — the home page's `_isToolOnly`
      // predicate classifies this as a tool-only bubble.
      toolCalls: [tc],
    );
  }

  Future<void> pumpGrouped(
    WidgetTester tester, {
    required List<ChatMessage> groupedMessages,
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
            body: MessageBubble(
              message: groupedMessages.first,
              groupedToolMessages: groupedMessages,
              onCopy: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('edited image gallery in grouped tool-call bubbles', () {
    testWidgets('renders the EditImageCard when a tool-only assistant bubble '
        'has an edit_image result', (tester) async {
      final m = _toolOnlyAssistantWithEditedImage();
      await pumpGrouped(
        tester,
        groupedMessages: [m],
        provider: _NoopChatProviderShim(),
      );

      // The collapsed summary card is still there.
      expect(find.text('1 tool calls'), findsOneWidget);

      // The gallery is rendered as a sibling of the summary
      // card (visible without expansion) — this is the bug
      // we're guarding against.
      expect(find.byType(EditImageCard), findsOneWidget);

      // The metadata caption ("Compress · 800×600 · 400.0 KB")
      // surfaces, confirming the gallery iterated the tool
      // call's `editedImages` list.
      expect(find.textContaining('Compress'), findsOneWidget);
      expect(find.textContaining('800×600'), findsOneWidget);
    });

    testWidgets('renders one EditImageCard per editedImage across multiple '
        'grouped bubbles', (tester) async {
      final first = _toolOnlyAssistantWithEditedImage(
        toolId: 'tc_edit_1',
        editedImage: EditedImage(
          path: 'C:/temp/edited_a.jpg',
          filename: 'edited_a.jpg',
          width: 800,
          height: 600,
          size: 409600,
          format: 'jpeg',
          action: 'compress',
        ),
      );
      final second = _toolOnlyAssistantWithEditedImage(
        toolId: 'tc_edit_2',
        editedImage: EditedImage(
          path: 'C:/temp/edited_b.png',
          filename: 'edited_b.png',
          width: 1200,
          height: 900,
          size: 655360,
          format: 'png',
          action: 'resize',
        ),
      );

      await pumpGrouped(
        tester,
        groupedMessages: [first, second],
        provider: _NoopChatProviderShim(),
      );

      expect(find.byType(EditImageCard), findsNWidgets(2));
      // Both action labels render — the gallery iterates every
      // tool call in the group, not just the first bubble's.
      expect(find.textContaining('Compress'), findsOneWidget);
      expect(find.textContaining('Resize'), findsOneWidget);
    });

    testWidgets('does NOT render any EditImageCard when the group has '
        'no edited images', (tester) async {
      final tc = ToolCall(
        id: 'tc_fetch',
        name: 'fetch_web',
        arguments: '{}',
        status: ToolCallStatus.success,
        result: '{}',
        // No editedImages — fetch_web doesn't produce any.
      );
      final m = ChatMessage(
        id: 'm_fetch',
        role: MessageRole.assistant,
        toolCalls: [tc],
      );

      await pumpGrouped(
        tester,
        groupedMessages: [m],
        provider: _NoopChatProviderShim(),
      );

      expect(find.byType(EditImageCard), findsNothing);
      // The summary card still shows.
      expect(find.text('1 tool calls'), findsOneWidget);
    });

    testWidgets('EditImageCard is visible WITHOUT expanding the '
        'collapsed card', (tester) async {
      // Regression guard: a future refactor that accidentally
      // moves the gallery behind the `_expanded` flag would
      // re-introduce the bug — the user would have to tap the
      // summary to see the image, defeating the "directly
      // visible in the bubble content area" design intent.
      final m = _toolOnlyAssistantWithEditedImage();
      await pumpGrouped(
        tester,
        groupedMessages: [m],
        provider: _NoopChatProviderShim(),
      );

      // The InkWell that flips `_expanded` is the summary row.
      // Walking the tree, the EditImageCard should be a sibling
      // of that InkWell, not nested inside it.
      final cardFinder = find.byType(EditImageCard);
      expect(cardFinder, findsOneWidget);

      final cardCenter = tester.getCenter(cardFinder);
      final summaryCenter = tester.getCenter(find.text('1 tool calls'));
      // Sanity: the card sits *below* the summary (not behind
      // it). This is a coarse ordering check — exact pixel
      // offsets are not asserted because they vary with font
      // metrics.
      expect(
        cardCenter.dy > summaryCenter.dy,
        isTrue,
        reason: 'gallery should render below the summary card',
      );
    });
  });
}

/// Empty `ChatProvider` shim — same trick used by
/// `message_bubble_ask_user_placement_test.dart`. We never call
/// any provider methods from the bubble, but the
/// `EditImageCard`'s Save button does `context.read<ChatProvider>()`
/// so we still need a valid instance to satisfy the type lookup.
class _NoopChatProviderShim extends ChangeNotifier implements ChatProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
