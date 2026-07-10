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

  group('ChatInput hint text', () {
    // Locks in the regression: while the model is replying the
    // input box used to fall back to the "please add a model"
    // hint (because `enabled` went false and the original code
    // had only two branches: enabled / not-enabled). The fix
    // adds a third branch — replying — so the user sees a
    // correct "Model is replying…" hint while the model is
    // in flight.
    Future<void> pumpWithState(
      WidgetTester tester, {
      required bool enabled,
      required bool sending,
      AppLocalizations? l10n,
    }) async {
      late AppLocalizations captured;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          supportedLocales: const [Locale('en'), Locale('zh')],
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = AppLocalizations.of(ctx);
                return ChatInput(
                  onSend: (_, _) {},
                  enabled: enabled,
                  sending: sending,
                  imageService: ImageService(),
                );
              },
            ),
          ),
        ),
      );
      l10n = captured;
    }

    testWidgets('shows the regular "say something" hint when ready', (
      tester,
    ) async {
      AppLocalizations? l10n;
      await pumpWithState(
        tester,
        enabled: true,
        sending: false,
        l10n: null,
      ).then(
        (_) =>
            l10n = AppLocalizations.of(tester.element(find.byType(ChatInput))),
      );
      // The text is hidden as a hint, so we need to find the
      // TextField's InputDecoration directly. Material renders
      // the hint as a Text descendant.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, l10n!.chatInputHint);
    });

    testWidgets('shows the "no model" hint when disabled and not sending', (
      tester,
    ) async {
      AppLocalizations? l10n;
      await pumpWithState(tester, enabled: false, sending: false, l10n: null);
      l10n = AppLocalizations.of(tester.element(find.byType(ChatInput)));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, l10n.chatInputHintNoModel);
    });

    testWidgets('shows the "replying" hint while the model is in flight', (
      tester,
    ) async {
      AppLocalizations? l10n;
      await pumpWithState(tester, enabled: false, sending: true, l10n: null);
      l10n = AppLocalizations.of(tester.element(find.byType(ChatInput)));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, l10n.chatInputHintReplying);
    });
  });
}
