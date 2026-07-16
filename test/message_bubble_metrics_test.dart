import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

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
        locale: const Locale('en'),
        home: Scaffold(
          body: MessageBubble(message: message, onCopy: (_) {}),
        ),
      ),
    );
  }

  // Convenience: build an assistant message with the three
  // metrics the user requested — TTFT, tps, and the total
  // token count (input + output). The chip rendering depends
  // on these three pieces of state being independently
  // observable.
  // ignore: no_leading_underscores_for_local_identifiers
  ChatMessage _assistantWithMetrics({
    Duration? ttft,
    Duration? decodeWindow,
    int outputTokens = 0,
    int inputTokens = 0,
  }) {
    final t = DateTime(2026, 1, 1, 10);
    return ChatMessage(
      id: 'a',
      role: MessageRole.assistant,
      content: 'hello',
      metrics: MessageMetrics(
        turnStartedAt: t,
        firstTokenAt: ttft == null ? null : t.add(ttft),
        lastTokenAt: ttft == null || decodeWindow == null
            ? null
            : t.add(ttft + decodeWindow),
        outputTokens: outputTokens,
        inputTokens: inputTokens,
      ),
    );
  }

  group('MessageBubble metric chips', () {
    testWidgets('renders nothing extra when metrics is null (legacy records)', (
      tester,
    ) async {
      final m = ChatMessage(
        id: 'a',
        role: MessageRole.assistant,
        content: 'hi',
      );
      await pumpBubble(tester, m);
      // The clock icon is part of the TTFT chip. If no chip is
      // rendered, the icon shouldn't appear.
      expect(find.byIcon(Icons.schedule_outlined), findsNothing);
      expect(find.textContaining('t/s'), findsNothing);
      expect(find.textContaining('token'), findsNothing);
    });

    testWidgets('renders the TTFT chip with clock icon and seconds label', (
      tester,
    ) async {
      final m = _assistantWithMetrics(
        ttft: const Duration(milliseconds: 500),
        decodeWindow: const Duration(seconds: 2),
        outputTokens: 50,
      );
      await pumpBubble(tester, m);
      // Clock icon for TTFT.
      expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
      // "0.50s" formatted by the bubble helper.
      expect(find.text('0.50s'), findsOneWidget);
    });

    testWidgets('renders the tps chip as "<n>t/s"', (tester) async {
      final m = _assistantWithMetrics(
        ttft: const Duration(milliseconds: 200),
        decodeWindow: const Duration(seconds: 1),
        outputTokens: 50,
      );
      await pumpBubble(tester, m);
      // 50 tokens / 1 second = 50.0 t/s → "50.0t/s".
      expect(find.text('50.0t/s'), findsOneWidget);
    });

    testWidgets('renders the total token chip with Σ glyph at the far right', (
      tester,
    ) async {
      final m = _assistantWithMetrics(
        ttft: const Duration(milliseconds: 500),
        decodeWindow: const Duration(seconds: 2),
        outputTokens: 800,
        inputTokens: 512,
      );
      await pumpBubble(tester, m);
      // Total = input (512) + output (800) = 1312.
      expect(find.text('Σ'), findsOneWidget);
      expect(find.text('1312token'), findsOneWidget);
    });

    testWidgets('omits the total chip when input + output is zero', (
      tester,
    ) async {
      final m = _assistantWithMetrics(
        ttft: const Duration(milliseconds: 100),
        decodeWindow: const Duration(seconds: 1),
        outputTokens: 0,
        inputTokens: 0,
      );
      await pumpBubble(tester, m);
      // TTFT chip is still shown, but no tps / no total.
      expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
      expect(find.textContaining('t/s'), findsNothing);
      expect(find.text('Σ'), findsNothing);
      expect(find.textContaining('token'), findsNothing);
    });

    testWidgets(
      'total counts both input and output (e.g. 3 in + 5 out → "8token")',
      (tester) async {
        final m = _assistantWithMetrics(
          ttft: const Duration(milliseconds: 100),
          decodeWindow: const Duration(milliseconds: 500),
          outputTokens: 5,
          inputTokens: 3,
        );
        await pumpBubble(tester, m);
        expect(find.text('8token'), findsOneWidget);
      },
    );

    testWidgets(
      'total still renders when the decode window is too short for a tps',
      (tester) async {
        // Output tokens but the decode window is effectively
        // zero (single chunk). The bubble drops the tps chip
        // (denominator would be 0) but keeps the total because
        // the user still wants to know how big this turn was.
        final m = _assistantWithMetrics(
          ttft: const Duration(milliseconds: 100),
          decodeWindow: Duration.zero,
          outputTokens: 800,
          inputTokens: 200,
        );
        await pumpBubble(tester, m);
        expect(find.textContaining('t/s'), findsNothing);
        // Total = 200 + 800 = 1000.
        expect(find.text('1000token'), findsOneWidget);
      },
    );

    testWidgets(
      'omits the TTFT chip when no first-token timestamp was recorded',
      (tester) async {
        final m = _assistantWithMetrics(
          ttft: null,
          decodeWindow: null,
          outputTokens: 100,
          inputTokens: 50,
        );
        await pumpBubble(tester, m);
        // No clock icon (TTFT missing) — but the total chip
        // still renders.
        expect(find.byIcon(Icons.schedule_outlined), findsNothing);
        expect(find.text('150token'), findsOneWidget);
      },
    );

    testWidgets('renders a sub-second TTFT with two decimals (e.g. "0.05s")', (
      tester,
    ) async {
      final m = _assistantWithMetrics(
        ttft: const Duration(milliseconds: 50),
        decodeWindow: const Duration(milliseconds: 250),
        outputTokens: 5,
      );
      await pumpBubble(tester, m);
      // 50ms = 0.05s — must show two decimals so the user
      // can read the difference vs. 0.50s at a glance.
      expect(find.text('0.05s'), findsOneWidget);
    });

    testWidgets('switches the TTFT chip to mm:ss once the value passes 60s', (
      tester,
    ) async {
      final m = _assistantWithMetrics(
        ttft: const Duration(minutes: 1, seconds: 5),
        decodeWindow: const Duration(seconds: 1),
        outputTokens: 10,
      );
      await pumpBubble(tester, m);
      expect(find.text('1m05s'), findsOneWidget);
    });
  });

  group('MessageBubble footer layout', () {
    testWidgets(
      'right-aligns the metric chips against the bubble edge via Spacer',
      (tester) async {
        // Footer lives BELOW the bubble, but the surrounding
        // [IntrinsicWidth] + stretch cross-axis aligns the footer
        // Row to the bubble's width, so the [Spacer] between the
        // copy button and the chips has real room to expand.
        final m = _assistantWithMetrics(
          ttft: const Duration(milliseconds: 200),
          decodeWindow: const Duration(seconds: 1),
          outputTokens: 50,
        );
        await pumpBubble(tester, m);
        // Every chip we expect to be present.
        expect(find.byIcon(Icons.schedule_outlined), findsOneWidget);
        expect(find.text('0.20s'), findsOneWidget);
        expect(find.text('50.0t/s'), findsOneWidget);
        // The footer must contain exactly one Spacer (the one
        // that pushes the chips to the right). If the
        // restructuring regresses, this count drops to zero.
        expect(find.byType(Spacer), findsOneWidget);
      },
    );

    testWidgets('footer Row is rendered even when the bubble itself is hidden '
        '(empty content + not streaming, with metrics)', (tester) async {
      // Edge case: model only emitted reasoning tokens (no
      // visible content), so the bubble is suppressed post-turn.
      // Unlike the previous "footer inside bubble" layout,
      // the footer now lives outside the bubble and still
      // renders — the user sees the timestamp + metrics chips
      // floating under where the bubble would have been.
      final m = ChatMessage(
        id: 'a',
        role: MessageRole.assistant,
        content: '',
        streaming: false,
        metrics: MessageMetrics(
          turnStartedAt: DateTime(2026, 1, 1, 10),
          firstTokenAt: DateTime(2026, 1, 1, 10, 0, 0, 100),
          outputTokens: 50,
          inputTokens: 10,
        ),
      );
      await pumpBubble(tester, m);
      // Total chip still shows (60 = 50 + 10).
      expect(find.text('Σ'), findsOneWidget);
      expect(find.text('60token'), findsOneWidget);
    });

    testWidgets(
      'footer Row shows the timestamp even with no content and no metrics',
      (tester) async {
        // Empty assistant message (legacy v1 record, no metrics,
        // no content). The footer should still render the
        // timestamp — that's the only signal the user has that
        // the message exists.
        final m = ChatMessage(
          id: 'a',
          role: MessageRole.assistant,
          content: '',
          streaming: false,
        );
        await pumpBubble(tester, m);
        // No chips at all.
        expect(find.byIcon(Icons.schedule_outlined), findsNothing);
        expect(find.textContaining('token'), findsNothing);
        // ...but the time string is still there.
        final t = DateFormat('HH:mm').format(m.createdAt.toLocal());
        expect(find.text(t), findsOneWidget);
      },
    );

    testWidgets('bubble shrink-wraps to its content — NOT stretched by a wider '
        'thinking block above', (tester) async {
      // The previous (reverted) layout wrapped the whole
      // assistant column in [IntrinsicWidth], which made the
      // bubble stretch to match the thinking block when
      // thinking was wider than the answer. During streaming
      // that looked hollow — the answer hugged the left edge
      // of an oversized bubble. The fix: scope IntrinsicWidth
      // to just the (bubble + footer) pair so the bubble
      // shrinks to its own content.
      final m = ChatMessage(
        id: 'a',
        role: MessageRole.assistant,
        content: 'ok', // narrow answer
        thinking:
            // artificially wide thinking block so the
            // regression would be unmistakable
            'a very long chain of thoughts that exceeds the '
            'width of the short answer and used to drag the '
            'bubble out to match',
        streaming: false,
      );
      // Use a localized finder so we can also verify the
      // thinking section actually rendered.
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
            body: SizedBox(
              width: 480,
              child: MessageBubble(message: m, onCopy: (_) {}),
            ),
          ),
        ),
      );
      // Both the thinking text and the bubble's "ok" should
      // be in the tree.
      expect(find.textContaining('chain of thoughts'), findsOneWidget);
      expect(find.text('ok'), findsOneWidget);
      final thinkingRect = tester.getRect(
        find.textContaining('chain of thoughts'),
      );
      final bubbleContentRect = tester.getRect(find.text('ok'));
      // Regression guard: the bubble's content must be
      // strictly narrower than the thinking block. If a
      // future change re-wraps the outer column in
      // [IntrinsicWidth], this assertion fails immediately.
      expect(
        bubbleContentRect.width,
        lessThan(thinkingRect.width),
        reason:
            'bubble is being stretched to the thinking block width — '
            'IntrinsicWidth leaked outside the (bubble + footer) pair',
      );
      // Sanity: the bubble should still have a sensible width
      // (more than just "ok" plus padding).
      expect(bubbleContentRect.width, greaterThan(20));
    });
  });
}
