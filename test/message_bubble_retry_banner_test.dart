import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  ChatMessage message,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('zh')],
      locale: const Locale('zh'),
      home: Scaffold(
        body: MessageBubble(
          message: message,
          onCopy: (_) {},
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('MessageBubble auto-retry banner', () {
    testWidgets(
      'renders the retry banner with the live countdown when '
      'isRetrying is true',
      (tester) async {
        final pumpedAt = DateTime.now();
        final nextAt = pumpedAt.add(const Duration(seconds: 7));
        final m = ChatMessage(
          id: 'm',
          role: MessageRole.assistant,
          retryAttempt: 2,
          nextRetryAt: nextAt,
        );
        await _pump(tester, m);

        final ctx = tester.element(find.byType(MessageBubble));
        final l10n = AppLocalizations.of(ctx);
        expect(l10n.localeName, 'zh');

        // The countdown string is computed at render time from
        // `nextAttemptAt - now`. We can't pin the wall-clock
        // difference exactly (the test framework may have
        // advanced ms during pumpWidget), so allow the rendered
        // seconds to be anything in [pumpedDiff, pumpedDiff-1]
        // — i.e. the value we set, or one less due to clock
        // drift.
        final expectedSeconds =
            (nextAt.difference(DateTime.now()).inSeconds).clamp(0, 7);
        final expected = l10n.chatRetryStatus('2', expectedSeconds.toString());
        // Verify the banner is present (substring match to
        // avoid code-point vs rendered-glyph diffs in CI logs).
        expect(find.textContaining('2 次重试'), findsOneWidget);
        expect(
          find.byWidgetPredicate((w) => w is Text && w.data == expected),
          findsOneWidget,
          reason: 'expected banner text "$expected" with attempt=2 and '
              'countdown around ${expectedSeconds}s',
        );
      },
    );

    testWidgets(
      'renders NO retry banner when retryAttempt is 0',
      (tester) async {
        final m = ChatMessage(id: 'm', role: MessageRole.assistant);
        await _pump(tester, m);
        // The banner uses the chatRetryStatus l10n key, which
        // is the only place that exact text appears. Make sure
        // nothing references it on a clean message.
        final ctx = tester.element(find.byType(MessageBubble));
        final l10n = AppLocalizations.of(ctx);
        expect(find.text(l10n.chatRetryStatus('1', '5')), findsNothing);
      },
    );

    testWidgets(
      'shows a fresh countdown label after nextAttemptAt updates',
      (tester) async {
        // Simulates the orchestrator's progression: bubble
        // starts with a 5-second countdown, the user waits,
        // the countdown ticks down to 2, then the bubble is
        // updated in place and we expect the new value to
        // appear immediately on the next rebuild.
        final m1 = ChatMessage(
          id: 'm',
          role: MessageRole.assistant,
          retryAttempt: 1,
          nextRetryAt: DateTime.now().add(const Duration(seconds: 5)),
        );

        late ChatMessage rebuilt;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en'), Locale('zh')],
            locale: const Locale('zh'),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  return MessageBubble(
                    message: m1,
                    onCopy: (_) {},
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        // Tick the clock between rebuilds by updating the
        // message state with a fresh, shorter countdown.
        rebuilt = m1.copyWith(
          nextRetryAt: DateTime.now().add(const Duration(seconds: 2)),
        );

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en'), Locale('zh')],
            locale: const Locale('zh'),
            home: Scaffold(
              body: MessageBubble(message: rebuilt, onCopy: (_) {}),
            ),
          ),
        );
        await tester.pump();

        // Verify the live countdown reflects the new
        // nextRetryAt (anywhere from 0..2 due to clock drift).
        final liveSeconds =
            rebuilt.nextRetryAt!.difference(DateTime.now()).inSeconds;
        final ctx = tester.element(find.byType(MessageBubble));
        final l10n = AppLocalizations.of(ctx);
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && w.data == l10n.chatRetryStatus(
              '1', liveSeconds.clamp(0, 2).toString(),
            ),
          ),
          findsOneWidget,
          reason: 'new countdown should be visible after rebuild',
        );
      },
    );

    testWidgets(
      'banner is hidden once the bubble transitions back to '
      'streaming state (next attempt started)',
      (tester) async {
        final midRetry = ChatMessage(
          id: 'm',
          role: MessageRole.assistant,
          retryAttempt: 1,
          nextRetryAt: DateTime.now().add(const Duration(seconds: 5)),
        );
        final streaming = ChatMessage(
          id: 'm',
          role: MessageRole.assistant,
          streaming: true,
          // retryAttempt defaults to 0 and nextRetryAt to null
          // (the orchestrator clears both via copyWith when the
          // backoff elapses).
        );

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en'), Locale('zh')],
            locale: const Locale('zh'),
            home: Scaffold(
              body: MessageBubble(
                message: midRetry,
                onCopy: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();

        // The banner is present during the retry wait.
        expect(find.textContaining('次重试'), findsOneWidget);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: const [Locale('en'), Locale('zh')],
            locale: const Locale('zh'),
            home: Scaffold(
              body: MessageBubble(
                message: streaming,
                onCopy: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();

        // Banner is gone now that retryAttempt=0.
        expect(find.textContaining('次重试'), findsNothing);
      },
    );
  });
}
