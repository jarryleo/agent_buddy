import 'package:agent_buddy/l10n/app_localizations.dart';
import 'package:agent_buddy/models/message.dart';
import 'package:agent_buddy/services/tts_service.dart';
import 'package:agent_buddy/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// A test-only `TtsService` whose lifecycle is fully under the
/// test's control. The widget never talks to a real platform —
/// it sees this fake via `Provider<TtsService>`.
class FakeTtsService implements TtsService {
  FakeTtsService({bool supported = true}) {
    isSupportedNotifier.value = supported;
  }

  // Kept for the (rare) test that needs to flip the flag at
  // runtime. Forwards to the notifier so the bubble's listener
  // fires and the UI rebuilds, mirroring the production path.
  set supported(bool v) {
    isSupportedNotifier.value = v;
  }

  bool get supported => isSupportedNotifier.value;

  @override
  final ValueNotifier<String?> speakingMessageId = ValueNotifier<String?>(null);
  @override
  final ValueNotifier<bool> isPausedNotifier = ValueNotifier<bool>(false);
  @override
  final ValueNotifier<bool> isSupportedNotifier = ValueNotifier<bool>(true);

  @override
  bool get isSupported => isSupportedNotifier.value;

  @override
  bool get isSpeaking => speakingMessageId.value != null;

  // Recorders for assertions.
  final List<_SpeakCall> speakCalls = [];
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String messageId, String text, {String? localeId}) async {
    speakCalls.add(
      _SpeakCall(messageId: messageId, text: text, localeId: localeId),
    );
    // Simulate the engine flipping the speaking id + state.
    speakingMessageId.value = messageId;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    speakingMessageId.value = null;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    isPausedNotifier.value = true;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    isPausedNotifier.value = false;
  }

  @override
  Future<void> dispose() async {
    speakingMessageId.dispose();
    isPausedNotifier.dispose();
    isSupportedNotifier.dispose();
  }

  /// Test helper: flip the speaking id without going through the
  /// normal speak/stop flow. Useful to simulate "another bubble
  /// is speaking" without touching the fake's speakCalls.
  void setSpeaking(String? id) {
    speakingMessageId.value = id;
  }

  void setPaused(bool paused) {
    isPausedNotifier.value = paused;
  }
}

class _SpeakCall {
  _SpeakCall({required this.messageId, required this.text, this.localeId});
  final String messageId;
  final String text;
  final String? localeId;
}

ChatMessage _assistant({
  String id = 'm1',
  String content = 'Hello world.',
  bool streaming = false,
}) {
  return ChatMessage(
    id: id,
    role: MessageRole.assistant,
    content: content,
    streaming: streaming,
  );
}

Future<void> _pumpBubble(
  WidgetTester tester, {
  required ChatMessage message,
  required TtsService tts,
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
        body: Provider<TtsService>.value(
          value: tts,
          child: MessageBubble(message: message, onCopy: (_) {}),
        ),
      ),
    ),
  );
  // The bubble attaches its TTS listeners in a post-frame
  // callback (`WidgetsBinding.instance.addPostFrameCallback`),
  // so we have to let one frame settle before the listener is
  // alive. Without this, swapping `speakingMessageId` via the
  // test fake doesn't trigger the bubble's `setState`.
  await tester.pump();
}

void main() {
  group('MessageBubble speaker button', () {
    testWidgets('renders the speaker at the bottom-right when supported', (
      tester,
    ) async {
      final tts = FakeTtsService();
      await _pumpBubble(tester, message: _assistant(), tts: tts);

      // Idle state → muted volume_up icon.
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      // No tooltips in the widget tree (we use Semantics instead).
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('hides the speaker when the platform reports no TTS', (
      tester,
    ) async {
      final tts = FakeTtsService(supported: false);
      await _pumpBubble(tester, message: _assistant(), tts: tts);

      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('speaker pops into view when the engine probe lands after the '
        'first render', (tester) async {
      // Reproduces the Windows startup race: TtsService.isSupported
      // starts as `false` because the platform probe hasn't
      // completed yet. The bubble must stay button-less until
      // the probe lands, then *rebuild* and show the speaker
      // without a hot-reload / scroll / other event.
      final tts = FakeTtsService(supported: false);
      await _pumpBubble(tester, message: _assistant(), tts: tts);

      // First paint: no speaker yet — the probe hasn't reported
      // a verdict.
      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);

      // Engine probe lands. Mutating the notifier should trigger
      // the bubble's listener → setState → rebuild → button
      // appears.
      tts.supported = true;
      await tester.pump();

      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    });

    testWidgets('hides the speaker when content is empty', (tester) async {
      final tts = FakeTtsService();
      await _pumpBubble(
        tester,
        message: _assistant(content: ''),
        tts: tts,
      );
      // Empty content → no TTS affordance. The rest of the
      // bubble (timestamp + copy) still renders.
      expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
    });

    testWidgets('tap on the speaker calls speak() with the bubble id + text', (
      tester,
    ) async {
      final tts = FakeTtsService();
      await _pumpBubble(
        tester,
        message: _assistant(id: 'm1', content: 'Hello world.'),
        tts: tts,
      );

      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await tester.pumpAndSettle();

      expect(tts.speakCalls, hasLength(1));
      expect(tts.speakCalls.first.messageId, 'm1');
      expect(tts.speakCalls.first.text, 'Hello world.');
      expect(tts.speakCalls.first.localeId, 'en-US');
    });

    testWidgets(
      'tap on a Chinese bubble forwards localeId=zh-CN to the engine',
      (tester) async {
        final tts = FakeTtsService();
        await _pumpBubble(
          tester,
          message: _assistant(content: '你好。'),
          tts: tts,
          locale: const Locale('zh'),
        );

        await tester.tap(find.byIcon(Icons.volume_up_rounded));
        await tester.pumpAndSettle();

        expect(tts.speakCalls.first.localeId, 'zh-CN');
        // Markdown / code fences are stripped, but plain
        // Chinese text without markdown passes through.
        expect(tts.speakCalls.first.text, '你好。');
      },
    );

    testWidgets('markdown formatting is stripped before speaking', (
      tester,
    ) async {
      final tts = FakeTtsService();
      await _pumpBubble(
        tester,
        message: _assistant(
          content: '# Title\n\nSome **bold** and `inline code` here.',
        ),
        tts: tts,
      );

      await tester.tap(find.byIcon(Icons.volume_up_rounded));
      await tester.pumpAndSettle();

      // The bubble sends the cleaned text (no `#`, no backticks,
      // no `**`) but the words themselves are preserved.
      expect(tts.speakCalls.first.text, contains('Title'));
      expect(tts.speakCalls.first.text, contains('bold'));
      expect(tts.speakCalls.first.text, contains('inline code'));
      expect(tts.speakCalls.first.text, isNot(contains('#')));
      expect(tts.speakCalls.first.text, isNot(contains('`')));
      expect(tts.speakCalls.first.text, isNot(contains('**')));
    });

    testWidgets(
      'while THIS bubble is speaking, the icon flips to stop + tap stops',
      (tester) async {
        final tts = FakeTtsService();
        await _pumpBubble(
          tester,
          message: _assistant(id: 'm1'),
          tts: tts,
        );

        // Toggle this bubble into "speaking" via the service.
        tts.setSpeaking('m1');
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.stop_rounded), findsOneWidget);

        await tester.tap(find.byIcon(Icons.stop_rounded));
        await tester.pumpAndSettle();

        expect(tts.stopCalls, 1);
      },
    );

    testWidgets(
      'while ANOTHER bubble is speaking, this one still shows the idle icon',
      (tester) async {
        final tts = FakeTtsService();
        await _pumpBubble(
          tester,
          message: _assistant(id: 'm1'),
          tts: tts,
        );

        tts.setSpeaking('m2');
        await tester.pumpAndSettle();

        // We shouldn't render the stop icon — m2 is the one
        // speaking, not us. Our affordance stays idle so the
        // user can queue up their own playback.
        expect(find.byIcon(Icons.stop_rounded), findsNothing);
        expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      },
    );

    testWidgets('paused state swaps the icon to play_arrow', (tester) async {
      final tts = FakeTtsService();
      await _pumpBubble(
        tester,
        message: _assistant(id: 'm1'),
        tts: tts,
      );

      tts.setSpeaking('m1');
      tts.setPaused(true);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byIcon(Icons.stop_rounded), findsNothing);
    });

    testWidgets('tap on the play_arrow resumes (rather than restarts)', (
      tester,
    ) async {
      final tts = FakeTtsService();
      await _pumpBubble(
        tester,
        message: _assistant(id: 'm1'),
        tts: tts,
      );

      tts.setSpeaking('m1');
      tts.setPaused(true);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pumpAndSettle();

      expect(tts.resumeCalls, 1);
      // speak() is NOT invoked for the resume path — the bubble
      // delegates to TtsService.resume().
      expect(tts.speakCalls, isEmpty);
    });
  });
}
