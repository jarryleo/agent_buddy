import 'dart:io';

import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpBubble(
    WidgetTester tester,
    ChatMessage message, {
    List<ChatMessage>? groupedToolMessages,
    Locale? locale,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        locale: locale,
        home: Scaffold(
          body: MessageBubble(
            message: message,
            onCopy: (_) {},
            groupedToolMessages: groupedToolMessages,
          ),
        ),
      ),
    );
  }

  group('MessageBubble hidden flag', () {
    testWidgets('hidden user message renders as SizedBox.shrink()', (
      tester,
    ) async {
      // Regression for the timer-driven flow: the chat provider
      // appends a synthetic "[系统计时触发] …" user message with
      // `hidden: true` so the model can react, but the UI must
      // not render it as a bubble. The bubble widget should
      // collapse to an empty SizedBox so the surrounding
      // ListView slot is left blank.
      final m = ChatMessage(
        id: 'h',
        role: MessageRole.user,
        content: '[系统计时触发] 喝水',
        hidden: true,
      );
      await pumpBubble(tester, m);
      // The text content never makes it into the tree.
      expect(find.text('[系统计时触发] 喝水'), findsNothing);
      // The bubble never built a Container (the chat list cell is
      // visibly empty). The Scaffold does not have a Container
      // child, so the only Container we'd see would be from the
      // user-bubble's own background — there should be none.
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('visible user message renders normally', (tester) async {
      final m = ChatMessage(id: 'v', role: MessageRole.user, content: 'Hello');
      await pumpBubble(tester, m);
      expect(find.text('Hello'), findsOneWidget);
      // Sanity: a visible user bubble has a real Container in the
      // tree (the bubble background).
      expect(find.byType(Container), findsWidgets);
    });

    testWidgets('image thumbnails preserve aspect ratio and crop to fill', (
      tester,
    ) async {
      final m = ChatMessage(
        id: 'image',
        role: MessageRole.user,
        content: '',
        imagePaths: [File('assets/icon/ic_app.png').absolute.path],
      );

      await pumpBubble(tester, m);

      final image = tester.widget<Image>(find.byType(Image));
      expect(image.fit, BoxFit.cover);
      expect(image.image, isA<ResizeImage>());
      expect((image.image as ResizeImage).policy, ResizeImagePolicy.fit);
    });
  });

  group('MessageBubble subagent card', () {
    testWidgets('shows only the report and can collapse again', (tester) async {
      final message = ChatMessage(
        id: 'tool-message',
        role: MessageRole.tool,
        toolCalls: [
          ToolCall(
            id: 'sub-1',
            name: 'subagent',
            arguments:
                '{"task":"private context","tool_calls":[{"error":"HTTP 500"}]}',
            status: ToolCallStatus.running,
            result: '有效结论正在生成',
            error: 'HTTP 500',
          ),
        ],
      );

      await pumpBubble(
        tester,
        message,
        groupedToolMessages: [message],
        locale: const Locale('zh'),
      );
      await tester.tap(find.text('调用了 1 个工具'));
      await tester.pump();

      expect(find.text('子 Agent'), findsOneWidget);
      expect(find.text('有效结论正在生成'), findsNothing);

      await tester.tap(find.text('子 Agent'));
      await tester.pump();

      expect(find.text('有效结论正在生成'), findsOneWidget);
      expect(find.textContaining('private context'), findsNothing);
      expect(find.textContaining('HTTP 500'), findsNothing);
      expect(find.text('参数'), findsNothing);

      await tester.tap(find.text('子 Agent'));
      await tester.pump();

      expect(find.text('有效结论正在生成'), findsNothing);
    });
  });
}
