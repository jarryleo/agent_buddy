import 'package:agent_buddy/widgets/pet_speech_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps `PetSpeechBubble` inside a tight 80-px-tall strip — the same
/// `Positioned(top: 6, height: 80)` slot the pet window uses in
/// production. The bubble's visual content is irrelevant to the
/// regression we're guarding against; we focus on visibility
/// transitions and layout stability.
Future<void> _pump(
  WidgetTester tester, {
  required String text,
  required bool visible,
  Duration fadeDuration = const Duration(milliseconds: 220),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 80,
          child: PetSpeechBubble(
            text: text,
            visible: visible,
            fadeDuration: fadeDuration,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('PetSpeechBubble visibility', () {
    testWidgets('visible=false with empty text targets zero opacity', (
      tester,
    ) async {
      await _pump(tester, text: '', visible: false);
      final animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 0.0);
    });

    testWidgets('visible=true with non-empty text targets full opacity', (
      tester,
    ) async {
      await _pump(tester, text: 'hi', visible: true);
      final animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 1.0);
    });

    testWidgets(
      'visible=false with non-empty text keeps the bubble body in the tree',
      (tester) async {
        // Regression for the "flash downward" bug: the auto-hide
        // timer flips `_speechVisible` to false while leaving
        // `_speechText` untouched, so the bubble's body must
        // continue to render (just under an AnimatedOpacity at
        // opacity 0). The previous implementation swapped the
        // bubble out for `SizedBox.shrink()`, which made the
        // bubble disappear instantly *and* shrink the slot —
        // the visible cause of the user-reported flash.
        await _pump(tester, text: 'still here', visible: false);

        final animatedOpacity = tester.widget<AnimatedOpacity>(
          find.byType(AnimatedOpacity),
        );
        expect(animatedOpacity.opacity, 0.0);
        expect(find.byType(Column), findsOneWidget);
        expect(find.text('still here'), findsOneWidget);
      },
    );

    testWidgets('IgnorePointer matches the derived shouldShow state', (
      tester,
    ) async {
      // The PetSpeechBubble widget installs its *own*
      // `IgnorePointer(ignoring: !shouldShow)` directly around the
      // `AnimatedOpacity`. The widget tree may contain unrelated
      // `IgnorePointer`s added by the test harness, so we narrow
      // the find to the AnimatedOpacity's parent — that's our
      // widget's IgnorePointer.
      IgnorePointer findOurIgnorePointer() => tester.widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byType(AnimatedOpacity),
              matching: find.byType(IgnorePointer),
            )
            .first,
      );

      await _pump(tester, text: 'hi', visible: false);
      expect(findOurIgnorePointer().ignoring, isTrue);

      await _pump(tester, text: 'hi', visible: true);
      expect(findOurIgnorePointer().ignoring, isFalse);

      // Empty text + visible=true: never reaches `shouldShow` so
      // pointer events must still be ignored.
      await _pump(tester, text: '', visible: true);
      expect(findOurIgnorePointer().ignoring, isTrue);
    });

    testWidgets('settles to target opacity after a full fade duration', (
      tester,
    ) async {
      await _pump(tester, text: 'fade-in', visible: false);
      var animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 0.0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 80,
              child: PetSpeechBubble(
                text: 'fade-in',
                visible: true,
                fadeDuration: const Duration(milliseconds: 200),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 1.0);
    });

    testWidgets('fades back to 0 when visible flips from true to false', (
      tester,
    ) async {
      await _pump(tester, text: 'fade-out', visible: true);
      var animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 1.0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 80,
              child: PetSpeechBubble(
                text: 'fade-out',
                visible: false,
                fadeDuration: const Duration(milliseconds: 200),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 0.0);
    });

    testWidgets(
      'bubble layout is identical at visible=true and visible=false — '
      'this is what stops the "flash downward" symptom',
      (tester) async {
        // The pet window pins the bubble to a fixed-height
        // `Positioned(top: 6, height: 80)`. The bubble itself must
        // not change that slot's intrinsic height across a
        // visibility flip — otherwise the bubble "jumps" when its
        // slot becomes empty vs full (the visible cause of the
        // user-reported "flash downward"). We assert the rendered
        // `Column` row span stays put across a visibility flip.
        await _pump(tester, text: 'stay', visible: true);
        final columnVisible = tester.renderObject<RenderBox>(
          find.byType(Column),
        );
        final columnVisibleSize = columnVisible.size;

        await _pump(tester, text: 'stay', visible: false);
        final columnHidden = tester.renderObject<RenderBox>(
          find.byType(Column),
        );
        expect(columnHidden.size, columnVisibleSize);

        // The bubble's body still mounts at opacity 0 —
        // no unmount/remount when crossing the visibility
        // boundary, which would otherwise cause the slot to
        // briefly shrink (the "flash"). Always-render contract.
        expect(find.byType(Column), findsOneWidget);
      },
    );

    testWidgets('changing text alone does not alter the target opacity', (
      tester,
    ) async {
      // Sanity check: the bubble must NOT re-fade when only the
      // text changes. (The fade-in-place implementation could
      // mistakenly re-run the opacity transition on every text
      // update, which would make the bubble pulse during the
      // chat response stream — visually nauseating.) The target
      // opacity only depends on the `visible` flag + text
      // emptiness, never on the text value itself.
      await _pump(tester, text: 'line 1', visible: true);
      var animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 1.0);

      await _pump(tester, text: 'line 1 - appended text', visible: true);
      animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.opacity, 1.0);
      expect(find.text('line 1 - appended text'), findsOneWidget);
    });

    testWidgets('fadeDuration is the duration on the AnimatedOpacity', (
      tester,
    ) async {
      // The pet window defers its bottom-anchored resize by
      // `fadeDuration + 30ms` to give the opacity animation time
      // to settle before the OS-level window re-anchors. If the
      // bubble's actual animation takes longer than the parent
      // expects, the window resize fires mid-fade and the
      // bubble "flashes" again. The two values must stay in
      // lockstep (see `kBubbleFadeDuration` in
      // `pet_window_page.dart`).
      await _pump(
        tester,
        text: 'duration',
        visible: true,
        fadeDuration: const Duration(milliseconds: 333),
      );
      final animatedOpacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(animatedOpacity.duration, const Duration(milliseconds: 333));
    });
  });
}
