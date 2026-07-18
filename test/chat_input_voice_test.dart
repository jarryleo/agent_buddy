import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/services/file_attachment_service.dart';
import 'package:agent_buddy/services/image_service.dart';
import 'package:agent_buddy/services/platform/calendar_service.dart'
    show PlatformPermissionStatus;
import 'package:agent_buddy/services/platform/voice_service.dart';
import 'package:agent_buddy/widgets/chat_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// A controllable fake [VoiceService] that lets tests push partial /
/// final transcripts + status events into the widget without touching
/// the microphone. Built on top of the public callbacks the UI
/// registers via [startListening].
class FakeVoiceService implements VoiceService {
  FakeVoiceService({
    this.permission = PlatformPermissionStatus.granted,
    this.available = true,
    this.errorOnFail = VoiceError.unknown,
  });

  final PlatformPermissionStatus permission;
  final bool available;
  final VoiceError errorOnFail;

  var ensurePermissionCalls = 0;
  var requestPermissionCalls = 0;
  var startListeningCalls = 0;
  var stopListeningCalls = 0;
  var cancelListeningCalls = 0;
  String? lastLocaleId;
  @override
  VoiceError lastError = VoiceError.none;
  bool _listening = false;
  VoiceResultCallback? _onResult;
  VoiceStatusCallback? _onStatus;
  VoiceLevelCallback? _onLevel;

  bool get listening => _listening;

  @override
  Future<PlatformPermissionStatus> ensurePermission() async {
    ensurePermissionCalls++;
    return permission;
  }

  @override
  Future<PlatformPermissionStatus> requestPermission() async {
    requestPermissionCalls++;
    return permission;
  }

  @override
  Future<bool> get isAvailable async => available;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> startListening({
    required VoiceResultCallback onResult,
    VoiceStatusCallback? onStatus,
    VoiceLevelCallback? onLevel,
    Duration listenFor = const Duration(seconds: 30),
    Duration pauseFor = const Duration(seconds: 8),
    String? localeId,
  }) async {
    if (!available ||
        permission == PlatformPermissionStatus.denied ||
        permission == PlatformPermissionStatus.permanentlyDenied) {
      lastError = errorOnFail;
      return false;
    }
    startListeningCalls++;
    lastLocaleId = localeId;
    _listening = true;
    lastError = VoiceError.none;
    _onResult = onResult;
    _onStatus = onStatus;
    _onLevel = onLevel;
    return true;
  }

  @override
  Future<void> stopListening() async {
    stopListeningCalls++;
    _listening = false;
  }

  @override
  Future<void> cancelListening() async {
    cancelListeningCalls++;
    _listening = false;
  }

  // ----- test helpers --------------------------------------------------

  void emitResult(String text, {bool finalResult = false}) {
    _onResult?.call(VoiceResult(text: text, finalResult: finalResult));
  }

  void emitStatus(String status) {
    _onStatus?.call(status);
  }

  void emitLevel(double level) {
    _onLevel?.call(level);
  }
}

Future<void> _pumpInput(
  WidgetTester tester, {
  required FakeVoiceService voice,
  required void Function(String, List<String>, List<Object?>) onSend,
  bool enabled = true,
  bool sending = false,
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
      locale: const Locale('en'),
      home: Scaffold(
        body: ChatInput(
          onSend: onSend,
          enabled: enabled,
          sending: sending,
          imageService: ImageService(),
          fileAttachmentService: const FileAttachmentService(),
          voiceService: voice,
        ),
      ),
    ),
  );
}

/// Fires a synthesized long-press sequence (start → move → end) at
/// the centre of [finder]. Long-press detection in Flutter needs the
/// pointer to stay put for ~500ms; we use Flutter's built-in
/// [WidgetTester.longPress] which already handles the timing
/// correctly. For the drag-to-cancel case the pointer is moved past
/// the recognizer's slop before being released.
Future<void> _longPress(
  WidgetTester tester,
  Finder finder, {
  double dragDelta = 0,
}) async {
  final center = tester.getCenter(finder);
  if (dragDelta == 0) {
    // Simple case: delegate to the framework's longPress helper.
    await tester.longPress(finder);
    return;
  }
  // Drag case: hold for the long-press timeout, then move past the
  // 80px cancel threshold before releasing.
  final gesture = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 600));
  await gesture.moveTo(center + Offset(dragDelta, 0));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.up();
  await tester.pump();
}

/// The action button in idle (non-listening) state. With text it's
/// an `ElevatedButton`; without text it's a mic-icon `Container`.
/// We find it by icon in each test (the icon is unique per state)
/// so this helper isn't needed.

/// Counts how many [FractionallySizedBox] widgets are mounted in
/// the tree. The codebase only uses it for the volume-meter bar
/// inside the input field's listening-state background, so the
/// delta between "not listening" and "listening" cleanly reflects
/// whether the bar is rendered. Hoisted to file scope so multiple
/// voice-input test groups can reuse it.
int fsbCount(WidgetTester t) =>
    find.byType(FractionallySizedBox).evaluate().length;

/// Finds the gradient-painted [Container] painted by the volume
/// meter (when listening) and returns its current
/// [LinearGradient.colors], or `null` when none is mounted.
List<Color>? gradientColors(WidgetTester t) {
  final matches = find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).gradient is LinearGradient,
  );
  if (matches.evaluate().isEmpty) return null;
  final container = t.widget<Container>(matches.first);
  final gradient =
      (container.decoration! as BoxDecoration).gradient! as LinearGradient;
  return gradient.colors;
}

void main() {
  group('ChatInput voice input — long-press start, release stop', () {
    testWidgets('long-press the mic button (empty input) starts voice', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      final sent = <String>[];
      await _pumpInput(tester, voice: voice, onSend: (t, _, _) => sent.add(t));

      // Empty input → mic button visible.
      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      expect(mic, findsOneWidget);

      // Use the manual long-press sequence (start + wait + end)
      // because `tester.longPress` doesn't always reliably fire
      // `onLongPressStart` on a gesture recognizer that only
      // declares start/move/end handlers (no plain `onLongPress`).
      final center = tester.getCenter(mic);
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        voice.requestPermissionCalls,
        1,
        reason:
            'manual long-press should fire onLongPressStart, which calls _startVoice, which calls requestPermission',
      );
      expect(voice.startListeningCalls, 1);
      expect(sent, isEmpty, reason: 'long-press should NOT send anything');
    });

    testWidgets('long-press the send button (non-empty input) starts voice', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      final sent = <String>[];
      await _pumpInput(tester, voice: voice, onSend: (t, _, _) => sent.add(t));

      // Type some text so the send button appears.
      await tester.enterText(find.byType(TextField), 'draft message');
      await tester.pump();

      final sendBtn = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.send_rounded),
      );
      expect(sendBtn, findsOneWidget);

      await _longPress(tester, sendBtn);
      await tester.pumpAndSettle();

      expect(
        voice.requestPermissionCalls,
        1,
        reason: 'long-press on send must trigger the same voice flow',
      );
      expect(voice.startListeningCalls, 1);
      expect(
        sent,
        isEmpty,
        reason:
            'long-press on the send button must NOT send the existing draft',
      );
    });

    testWidgets('partial transcript is mirrored live into the input box', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await _pumpInput(tester, voice: voice, onSend: (_, _, _) {});

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();

      // Engine reports it's actually listening.
      voice.emitStatus('listening');
      await tester.pump();

      // Partial transcript streams in.
      voice.emitResult('hello');
      await tester.pump();
      voice.emitResult('hello world');
      await tester.pump();

      // The input box should now mirror "hello world" live.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'hello world');
    });

    testWidgets(
      'release after recording leaves text in the input box (no auto-send)',
      (tester) async {
        final voice = FakeVoiceService();
        final sent = <String>[];
        await _pumpInput(
          tester,
          voice: voice,
          onSend: (t, _, _) => sent.add(t),
        );

        final mic = find.descendant(
          of: find.byType(ChatInput),
          matching: find.byIcon(Icons.mic_none_rounded),
        );
        await _longPress(tester, mic);
        await tester.pumpAndSettle();

        voice.emitStatus('listening');
        voice.emitResult('hi there');
        voice.emitResult('hi there, how are you', finalResult: true);
        await tester.pump();

        // Now we need to simulate the long-press *end*. The
        // longPress helper already released the gesture; we just
        // need to pump the engine a bit.
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(
          field.controller!.text,
          'hi there, how are you',
          reason: 'text should be in the box for the user to review',
        );
        expect(
          sent,
          isEmpty,
          reason: 'release must NOT auto-send the transcribed text',
        );
      },
    );

    testWidgets('drag-away-to-cancel discards the partial transcript', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      final sent = <String>[];
      await _pumpInput(tester, voice: voice, onSend: (t, _, _) => sent.add(t));

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      // Long-press with a 200px drag to the right (well over the
      // 80px cancel threshold).
      await _longPress(tester, mic, dragDelta: 200);
      await tester.pumpAndSettle();

      voice.emitStatus('listening');
      voice.emitResult('partial garbage');
      await tester.pump();
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller!.text,
        '',
        reason:
            'drag-to-cancel should restore the input to its pre-recording state',
      );
      expect(sent, isEmpty);
    });

    testWidgets(
      'permission denied (permanently) shows the right snackbar + never starts',
      (tester) async {
        final voice = FakeVoiceService(
          permission: PlatformPermissionStatus.permanentlyDenied,
          errorOnFail: VoiceError.permanentlyDenied,
        );
        final sent = <String>[];
        await _pumpInput(
          tester,
          voice: voice,
          onSend: (t, _, _) => sent.add(t),
        );

        final mic = find.descendant(
          of: find.byType(ChatInput),
          matching: find.byIcon(Icons.mic_none_rounded),
        );
        await _longPress(tester, mic);
        await tester.pumpAndSettle();

        expect(voice.requestPermissionCalls, 1);
        expect(
          voice.startListeningCalls,
          0,
          reason:
              'engine should not be asked to start when permission is denied',
        );
        expect(sent, isEmpty);

        // The snackbar should be visible.
        expect(
          find.textContaining('permanently', findRichText: true),
          findsOneWidget,
        );
      },
    );

    testWidgets('listening: tap on the pulsing mic stops recording (no send)', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      final sent = <String>[];
      await _pumpInput(tester, voice: voice, onSend: (t, _, _) => sent.add(t));

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();
      voice.emitStatus('listening');
      voice.emitResult('captured');
      await tester.pump();

      // The mic icon is now the solid `mic` (pulsing); tap it.
      // The voice bar also shows a (different) mic icon at 16px,
      // so we filter on size to target the action button.
      final pulsingMic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.mic && w.size == 18,
        ),
      );
      expect(pulsingMic, findsOneWidget);
      await tester.tap(pulsingMic);
      await tester.pumpAndSettle();

      expect(voice.stopListeningCalls, 1);
      expect(
        sent,
        isEmpty,
        reason: 'tap-to-stop must not send; text just stays in the box',
      );
    });
  });

  group('ChatInput voice input — bug fixes + volume meter', () {
    // [fsbCount] / [gradientColors] are defined as top-level
    // helpers above `main()` so the voice-input groups below can
    // share them.

    testWidgets(
      'first partial result flips _voiceActuallyStarted (no onStatus needed)',
      (tester) async {
        final voice = FakeVoiceService();
        final sent = <String>[];
        await _pumpInput(
          tester,
          voice: voice,
          onSend: (t, _, _) => sent.add(t),
        );

        final mic = find.descendant(
          of: find.byType(ChatInput),
          matching: find.byIcon(Icons.mic_none_rounded),
        );
        await _longPress(tester, mic);
        await tester.pumpAndSettle();

        // Engine reports a partial result WITHOUT first reporting
        // status='listening'. This is the Windows scenario where
        // the WinRT speech recognizer streams results before any
        // status callback fires — and was the bug behind the
        // "无法启动语音输入" snackbar (the release path bailed
        // because `actuallyStarted` was never set).
        voice.emitResult('hello');
        await tester.pump();

        // Tapping the (now-pulsing, because started) mic stops the
        // session cleanly.
        final pulsingMic = find.descendant(
          of: find.byType(ChatInput),
          matching: find.byWidgetPredicate(
            (w) => w is Icon && w.icon == Icons.mic && w.size == 18,
          ),
        );
        expect(pulsingMic, findsOneWidget);
        await tester.tap(pulsingMic);
        await tester.pumpAndSettle();

        expect(
          voice.stopListeningCalls,
          1,
          reason:
              'first result must flip _voiceActuallyStarted → tap-to-stop works',
        );
      },
    );

    testWidgets('input field shows the gradient volume bar while listening', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await _pumpInput(tester, voice: voice, onSend: (_, _, _) {});
      final beforeFsbCount = fsbCount(tester);
      expect(beforeFsbCount, 0, reason: 'no volume bar before voice starts');

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();
      voice.emitStatus('listening');
      await tester.pump();

      expect(
        fsbCount(tester),
        beforeFsbCount + 1,
        reason:
            'a FractionallySizedBox (the volume bar) is mounted during listening',
      );
      expect(gradientColors(tester), isNotNull);
    });

    testWidgets('synthetic level bumps with each new partial', (tester) async {
      final voice = FakeVoiceService();
      await _pumpInput(tester, voice: voice, onSend: (_, _, _) {});

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();
      voice.emitStatus('listening');
      await tester.pump();

      // The volume bar is rendered with a baseline factor of 0.02
      // (very thin sliver). At rest, no real onLevel callback has
      // fired (Windows doesn't reliably emit one) so the bar's
      // factor floor is the 2% baseline.
      var factor =
          (tester
              .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
              .widthFactor!) -
          0.02;
      expect(factor, lessThan(0.05), reason: 'baseline factor is ~2% at rest');

      // Push a partial transcript — the synthetic-level bump
      // should drive the widthFactor well above the baseline.
      voice.emitResult('hello');
      // TweenAnimationBuilder interpolates 0 → level over 110ms;
      // pump past that so we observe the settled meter width.
      await tester.pump(const Duration(milliseconds: 130));
      factor = tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor!;
      expect(
        factor,
        greaterThan(0.3),
        reason:
            'a partial result must bump the synthetic level so the meter visibly responds',
      );

      // After ~500ms of no further results the decay timer
      // should have ticked the bar back below the peak.
      await tester.pump(const Duration(milliseconds: 500));
      // Final factor is non-zero (the baseline keeps the bar
      // visible) and below the peak we just saw.
      final decayed = tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor!;
      expect(decayed, lessThan(factor));
      expect(decayed, greaterThanOrEqualTo(0.02));
    });

    testWidgets('real amplitude (onLevel) drives the bar directly', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await _pumpInput(tester, voice: voice, onSend: (_, _, _) {});
      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();
      voice.emitStatus('listening');
      await tester.pump();

      // Real amplitude at the noisy end of the spectrum (~0.9)
      // should drive the bar above 80%. `pumpAndSettle` lets the
      // 110 ms tween animation fully run to completion (no
      // periodic timers are scheduled by the real-amplitude path
      // so settle does terminate).
      voice.emitLevel(0.9);
      await tester.pumpAndSettle();
      final factor = tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor!;
      expect(
        factor,
        greaterThan(0.75),
        reason: 'real-amplitude callback must dominate over synthetic',
      );
    });

    testWidgets('drag-to-cancel switches the bar to the red palette', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await _pumpInput(tester, voice: voice, onSend: (_, _, _) {});
      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );

      // Hold the press without releasing so we can inspect the
      // palette mid-drag.
      final center = tester.getCenter(mic);
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 600));
      voice.emitStatus('listening');
      voice.emitResult('partial');
      voice.emitLevel(0.7);
      await tester.pump();

      // Normal meter — green dominant.
      final normalColors = gradientColors(tester);
      expect(
        normalColors,
        isNotNull,
        reason: 'volume bar renders while listening',
      );
      expect(
        normalColors!.first.g,
        greaterThan(normalColors.first.r),
        reason:
            'active meter starts with green (meter palette, not cancel palette)',
      );

      // Drag past the 80px threshold WITHOUT releasing. The bar
      // palette must switch to the red-only cancel ramp while
      // still being mounted (the gesture is still down).
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      final dragColors = gradientColors(tester);
      expect(
        dragColors,
        isNotNull,
        reason: 'bar remains mounted while dragging',
      );
      expect(
        dragColors!.first.r,
        greaterThan(dragColors.first.g),
        reason:
            'drag-cancel palette is dominated by red, not the green/yellow/red meter',
      );

      // Now release — listening ends, bar unmounts.
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('volume bar disappears once listening ends', (tester) async {
      final voice = FakeVoiceService();
      await _pumpInput(tester, voice: voice, onSend: (_, _, _) {});
      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );

      // Long-press → drag → release (drag-cancel flow).
      final center = tester.getCenter(mic);
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 600));
      voice.emitStatus('listening');
      voice.emitResult('captured');
      await tester.pump();

      expect(
        fsbCount(tester),
        greaterThan(0),
        reason: 'bar mounts during listening',
      );

      // Release after dragging past threshold — listening
      // cleanly tears down, the bar unmounts.
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(fsbCount(tester), 0, reason: 'bar unmounts once the session ends');
      expect(gradientColors(tester), isNull);
    });
  });

  group('ChatInput voice input — locale + auto-exit mid-press', () {
    /// Pumps the input inside a localised [MaterialApp] using the
    /// given [Locale] so we can assert that the right `localeId`
    /// gets forwarded to the speech engine.
    Future<void> pumpWithLocale(
      WidgetTester tester,
      FakeVoiceService voice,
      void Function(String, List<String>, List<Object?>) onSend, {
      Locale locale = const Locale('en'),
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
            body: ChatInput(
              onSend: onSend,
              enabled: true,
              imageService: ImageService(),
              fileAttachmentService: const FileAttachmentService(),
              voiceService: voice,
            ),
          ),
        ),
      );
    }

    testWidgets('zh locale forwards localeId=zh-CN to the engine', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await pumpWithLocale(
        tester,
        voice,
        (_, _, _) {},
        locale: const Locale('zh'),
      );

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();

      expect(
        voice.lastLocaleId,
        'zh-CN',
        reason:
            'a Chinese app locale must select the Chinese STT model (BCP-47 '
            '`zh-CN` is what `stts` passes through to the native recognizer) '
            'so WinRT does not fall back to the system (often English) locale',
      );
    });

    testWidgets('en locale forwards localeId=en-US to the engine', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await pumpWithLocale(
        tester,
        voice,
        (_, _, _) {},
        locale: const Locale('en'),
      );

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      await _longPress(tester, mic);
      await tester.pumpAndSettle();

      expect(voice.lastLocaleId, 'en-US');
    });

    testWidgets(
      'engine firing notListening mid-press does NOT flip the UI to idle',
      (tester) async {
        // Repro for the Windows "session auto-exits while I'm still
        // long-pressing" bug: the WinRT recognizer's pauseFor fires
        // `notListening` while the user is still holding the button.
        // The visual listening state (pulsing mic, voice bar above
        // input, gradient volume bar) must stay mounted — the UI
        // listens to the user's intent (long-press), not the
        // engine's lifecycle.
        final voice = FakeVoiceService();
        await pumpWithLocale(tester, voice, (_, _, _) {});

        final mic = find.descendant(
          of: find.byType(ChatInput),
          matching: find.byIcon(Icons.mic_none_rounded),
        );
        final center = tester.getCenter(mic);
        final gesture = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 600));
        voice.emitStatus('listening');
        voice.emitResult('partial transcript');
        await tester.pump();

        expect(
          fsbCount(tester),
          greaterThan(0),
          reason: 'volume bar mounted during listening',
        );
        expect(
          gradientColors(tester),
          isNotNull,
          reason: 'listening gradient is mounted',
        );

        // Engine voluntarily ends (e.g. WinRT's pauseFor fired).
        voice.emitStatus('notListening');
        await tester.pump();

        // UI must STILL be in listening mode.
        expect(
          fsbCount(tester),
          greaterThan(0),
          reason: 'volume bar must stay mounted after engine ends mid-press',
        );
        expect(
          gradientColors(tester),
          isNotNull,
          reason: 'listening gradient must stay mounted mid-press',
        );

        // Late partial that arrives after the engine ended must
        // NOT clobber the input box — the transcript is already
        // there from the live updates.
        voice.emitResult('late garbage');
        await tester.pump();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(
          field.controller!.text,
          'partial transcript',
          reason:
              'late results after engine ended must not overwrite the live transcript',
        );

        // Now release — the session should be cleanly torn down
        // and the UI should return to idle.
        await gesture.up();
        await tester.pumpAndSettle();

        expect(voice.stopListeningCalls, 1);
        expect(fsbCount(tester), 0);
        expect(gradientColors(tester), isNull);
      },
    );

    testWidgets('engine firing done mid-press does NOT flip the UI to idle', (
      tester,
    ) async {
      final voice = FakeVoiceService();
      await pumpWithLocale(tester, voice, (_, _, _) {});

      final mic = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byIcon(Icons.mic_none_rounded),
      );
      final center = tester.getCenter(mic);
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 600));
      voice.emitStatus('listening');
      voice.emitResult('hi there', finalResult: true);
      await tester.pump();

      // Engine fires `done` after the final result.
      voice.emitStatus('done');
      await tester.pump();

      expect(
        fsbCount(tester),
        greaterThan(0),
        reason: 'volume bar stays mounted after engine fires done mid-press',
      );

      // Release — properly tears down.
      await gesture.up();
      await tester.pumpAndSettle();

      expect(voice.stopListeningCalls, 1);
      expect(fsbCount(tester), 0);
    });

    testWidgets(
      'release after engine auto-ended (no results) still cleans up UI',
      (tester) async {
        // Edge case: user long-presses the mic but stays silent for
        // long enough that the engine's pauseFor fires — never
        // produces a result, never reports 'listening'. The user
        // eventually releases. The session must still be torn down
        // even though `_voiceActuallyStarted` was never set.
        final voice = FakeVoiceService();
        await pumpWithLocale(tester, voice, (_, _, _) {});

        final mic = find.descendant(
          of: find.byType(ChatInput),
          matching: find.byIcon(Icons.mic_none_rounded),
        );
        final center = tester.getCenter(mic);
        final gesture = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 600));

        // Engine ends without ever reporting `listening` or any
        // result — pure pauseFor timeout.
        voice.emitStatus('notListening');
        await tester.pump();

        // Release.
        await gesture.up();
        await tester.pumpAndSettle();

        expect(
          voice.stopListeningCalls,
          1,
          reason:
              'release after engine auto-end must still call stopListening '
              'to reset the UI',
        );
        expect(fsbCount(tester), 0);
        expect(gradientColors(tester), isNull);
      },
    );
  });
}
