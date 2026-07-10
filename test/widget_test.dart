import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/services/api_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/widgets/chat_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ApiService constructs', () {
    final api = ApiService();
    expect(api, isNotNull);
  });

  group('ChatInput Enter behavior', () {
    Future<void> pumpInput(WidgetTester tester, void Function(String) onSend) {
      return tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          home: Scaffold(
            body: ChatInput(
              onSend: (text, images) => onSend(text),
              enabled: true,
              imageService: ImageService(),
            ),
          ),
        ),
      );
    }

    testWidgets('Enter sends the message on desktop', (tester) async {
      final sent = <String>[];
      await pumpInput(tester, sent.add);

      await tester.enterText(find.byType(TextField), 'hello world');
      // Plain Enter (no modifier) is the desktop "send" combo.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, contains('hello world'));
    });

    testWidgets('Ctrl+Enter does NOT submit (lets the newline through)', (
      tester,
    ) async {
      final sent = <String>[];
      await pumpInput(tester, sent.add);

      await tester.enterText(find.byType(TextField), 'line one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets('Alt+Enter does NOT submit', (tester) async {
      final sent = <String>[];
      await pumpInput(tester, sent.add);

      await tester.enterText(find.byType(TextField), 'line one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets('Meta+Enter does NOT submit (macOS Cmd+Enter)', (tester) async {
      final sent = <String>[];
      await pumpInput(tester, sent.add);

      await tester.enterText(find.byType(TextField), 'line one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();

      expect(sent, isEmpty);
    });
  });
}
