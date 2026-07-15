import 'dart:io';

import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpBubble(WidgetTester tester, ChatMessage message) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        home: Scaffold(
          body: MessageBubble(message: message, onCopy: (_) {}),
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
}
