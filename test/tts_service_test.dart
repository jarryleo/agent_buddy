import 'dart:async';

import 'package:agent_buddy/services/tts_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stts/stts.dart';

/// A controllable [TtsPlatformInterface] used to exercise
/// [TtsService] without producing real audio. Lets the test dictate
/// the return value of `isSupported()` / `start()` / `stop()` /
/// `dispose()` and push [TtsState] events into the engine's
/// broadcast stream so the wrapper's notifier wiring can be
/// observed.
///
/// Mirrors the same pattern the STT test uses: install the fake
/// as `TtsPlatformInterface.instance` in `setUp`, then construct
/// `Tts()` — `Tts`'s constructor pulls from the platform-interface
/// singleton.
class _FakeTtsPlatform extends TtsPlatformInterface {
  bool supported = true;
  int startInvocations = 0;
  int stopInvocations = 0;
  int pauseInvocations = 0;
  int resumeInvocations = 0;
  int setLanguageInvocations = 0;
  String? lastLanguage;
  String? lastText;
  TtsOptions? lastOptions;
  bool startThrows = false;
  bool emitStopOnStop = true;

  final StreamController<TtsState> _stateCtrl =
      StreamController<TtsState>.broadcast();

  @override
  Stream<TtsState> get onStateChanged => _stateCtrl.stream;

  @override
  Future<bool> isSupported() async => supported;

  @override
  Future<void> start(
    String text, {
    TtsOptions options = const TtsOptions(),
  }) async {
    startInvocations++;
    lastText = text;
    lastOptions = options;
    if (startThrows) {
      throw PlatformException(code: 'synth_failed', message: 'boom');
    }
  }

  @override
  Future<void> stop() async {
    stopInvocations++;
    if (emitStopOnStop) {
      _stateCtrl.add(TtsState.stop);
    }
  }

  @override
  Future<void> pause() async {
    pauseInvocations++;
    // Mirror what the real platform does — fire the state change
    // so the wrapper's `isPausedNotifier` flips true. Without
    // this, idempotency tests (calling pause twice) would
    // observe the wrapper's flag stuck on `false` and re-fire.
    _stateCtrl.add(TtsState.pause);
  }

  @override
  Future<void> resume() async {
    resumeInvocations++;
    // `resume()` is the dual of `pause()` — the engine flips back
    // to `TtsState.start` per `stts`'s convention, so we mirror it
    // here as well.
    _stateCtrl.add(TtsState.start);
  }

  @override
  Future<String> getLanguage() async => lastLanguage ?? 'en-US';

  @override
  Future<void> setLanguage(String language) async {
    setLanguageInvocations++;
    lastLanguage = language;
  }

  @override
  Future<List<String>> getLanguages() async => const ['en-US', 'zh-CN'];

  @override
  Future<List<TtsVoice>> getVoices() async => const [];

  @override
  Future<List<TtsVoice>> getVoicesByLanguage(String language) async => const [];

  @override
  Future<void> setVoice(String voiceId) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {}

  // ----- test helpers --------------------------------------------------

  /// Inject a [TtsState] event into the engine's state stream. The
  /// wrapper's state listener forwards it into
  /// [speakingMessageId] / [isPausedNotifier] accordingly.
  void emitState(TtsState state) => _stateCtrl.add(state);

  /// Convenience: simulate the engine starting to speak. Synchronous.
  void emitStart() => emitState(TtsState.start);

  /// Convenience: simulate the engine pausing. Synchronous.
  void emitPause() => emitState(TtsState.pause);

  /// Convenience: simulate the engine stopping — either because the
  /// user tapped stop, or because the utterance finished naturally.
  void emitStop() => emitState(TtsState.stop);

  Future<void> close() async {
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeTtsPlatform platform;
  late TtsPlatformInterface savedInstance;

  setUp(() {
    platform = _FakeTtsPlatform();
    savedInstance = TtsPlatformInterface.instance;
    TtsPlatformInterface.instance = platform;
  });

  tearDown(() async {
    TtsPlatformInterface.instance = savedInstance;
    await platform.close();
  });

  TtsService buildService() => TtsService();

  group('TtsService — supported path', () {
    test('speak() proxies to the engine + records the messageId', () async {
      final svc = buildService();
      await svc.speak('m1', 'hello world', localeId: 'zh-CN');
      expect(platform.startInvocations, 1);
      expect(platform.lastText, 'hello world');
      if (defaultTargetPlatform == TargetPlatform.windows) {
        expect(platform.lastOptions?.preSilence, Duration.zero);
        expect(platform.lastOptions?.postSilence, Duration.zero);
      } else {
        expect(platform.lastOptions?.preSilence, isNull);
        expect(platform.lastOptions?.postSilence, isNull);
      }
      expect(platform.setLanguageInvocations, 1);
      expect(platform.lastLanguage, 'zh-CN');
      expect(svc.speakingMessageId.value, 'm1');
      expect(svc.isPausedNotifier.value, isFalse);
    });

    test('Windows speech text is escaped for the native XML parser', () async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = previous;
      });
      final svc = buildService();
      await svc.speak('m1', 'Tom & Jerry <code> "quoted" \'raw\'');
      expect(
        platform.lastText,
        'Tom &amp; Jerry &lt;code&gt; &quot;quoted&quot; &apos;raw&apos;',
      );
    });

    test(
      'engine TtsState.start keeps the speaking id and clears pause',
      () async {
        final svc = buildService();
        await svc.speak('m1', 'hi');
        platform.emitPause();
        await Future<void>.delayed(Duration.zero);
        expect(svc.isPausedNotifier.value, isTrue);
        platform.emitStart();
        await Future<void>.delayed(Duration.zero);
        expect(svc.isPausedNotifier.value, isFalse);
        expect(svc.speakingMessageId.value, 'm1');
      },
    );

    test('engine TtsState.stop clears speakingMessageId', () async {
      final svc = buildService();
      await svc.speak('m1', 'hi');
      expect(svc.speakingMessageId.value, 'm1');
      platform.emitStop();
      await Future<void>.delayed(Duration.zero);
      expect(svc.speakingMessageId.value, isNull);
      expect(svc.isPausedNotifier.value, isFalse);
    });

    test('tapping the same id again toggles playback off', () async {
      final svc = buildService();
      await svc.speak('m1', 'hi');
      expect(svc.speakingMessageId.value, 'm1');
      await svc.speak('m1', 'hi');
      expect(svc.speakingMessageId.value, isNull);
      expect(platform.stopInvocations, 1);
      // Tapped the same id, so we should NOT have called start
      // a second time.
      expect(platform.startInvocations, 1);
    });

    test('tapping a different id swaps the playback target', () async {
      final svc = buildService();
      await svc.speak('m1', 'first');
      expect(svc.speakingMessageId.value, 'm1');
      await svc.speak('m2', 'second');
      // The previous in-flight utterance is stopped first…
      expect(platform.stopInvocations, greaterThanOrEqualTo(1));
      // …and then the new one kicks off.
      expect(platform.startInvocations, 2);
      expect(svc.speakingMessageId.value, 'm2');
    });

    test('stop() with nothing playing is a no-op (no engine call)', () async {
      final svc = buildService();
      await svc.stop();
      expect(platform.stopInvocations, 0);
    });

    test('stop() with something playing forwards to the engine', () async {
      final svc = buildService();
      await svc.speak('m1', 'hi');
      await svc.stop();
      expect(platform.stopInvocations, 1);
    });

    test('stop() clears state even without an engine stop event', () async {
      final svc = buildService();
      await svc.speak('m1', 'hi');
      platform.emitStopOnStop = false;
      await svc.stop();
      expect(svc.speakingMessageId.value, isNull);
      expect(svc.isPausedNotifier.value, isFalse);
    });

    test(
      'pause() / resume() only fire when an utterance is in flight',
      () async {
        final svc = buildService();
        // No utterance yet → both no-ops.
        await svc.pause();
        await svc.resume();
        expect(platform.pauseInvocations, 0);
        expect(platform.resumeInvocations, 0);

        await svc.speak('m1', 'hi');
        await svc.pause();
        await svc.pause(); // idempotent
        await svc.resume();
        await svc.resume(); // idempotent
        expect(platform.pauseInvocations, 1);
        expect(platform.resumeInvocations, 1);
      },
    );

    test('engine throwing on start clears speakingMessageId', () async {
      platform.startThrows = true;
      final svc = buildService();
      await svc.speak('m1', 'hi');
      // Engine rejected → wrapper didn't set the id, and the
      // speaking-message id stays null. (The engine may have
      // thrown synchronously, in which case nothing got set.)
      expect(svc.speakingMessageId.value, isNull);
    });

    test('localeId is forwarded to setLanguage()', () async {
      final svc = buildService();
      await svc.speak('m1', 'hello', localeId: 'en-US');
      expect(platform.lastLanguage, 'en-US');
    });

    test('null localeId skips setLanguage()', () async {
      final svc = buildService();
      await svc.speak('m1', 'hello');
      expect(platform.setLanguageInvocations, 0);
    });

    test('whitespace-only text is a no-op', () async {
      final svc = buildService();
      await svc.speak('m1', '   \n\n ');
      expect(platform.startInvocations, 0);
      expect(svc.speakingMessageId.value, isNull);
    });
  });

  group('TtsService — unsupported path', () {
    test('isSupported flips false on a platform that returns false', () async {
      platform.supported = false;
      final svc = buildService();
      await svc.initialize();
      expect(svc.isSupported, isFalse);
    });

    test('speak() quietly no-ops on an unsupported platform', () async {
      platform.supported = false;
      final svc = buildService();
      await svc.speak('m1', 'hi');
      expect(platform.startInvocations, 0);
      expect(svc.speakingMessageId.value, isNull);
    });
  });

  group('TtsService — listener notifications', () {
    test(
      'speakingMessageId fires its listeners when start / stop arrive',
      () async {
        final svc = buildService();
        var fired = 0;
        svc.speakingMessageId.addListener(() => fired++);
        await svc.speak('m1', 'hi');
        expect(fired, 1, reason: 'speak() flipped id from null → m1');
        platform.emitStop();
        await Future<void>.delayed(Duration.zero);
        expect(fired, 2, reason: 'engine stop flipped m1 → null');
      },
    );

    test('isSupportedNotifier flips after initialize()', () async {
      // The notifier is the source of truth for the bubble's
      // "is the engine available?" check, and the bubble's
      // initState reads the live value once via a post-frame
      // callback. Without this notifier flipping on the first
      // probe, the bubble would stay button-less forever.
      final svc = buildService();
      expect(svc.isSupportedNotifier.value, isFalse);
      expect(svc.isSupported, isFalse);

      var fired = 0;
      svc.isSupportedNotifier.addListener(() => fired++);

      await svc.initialize();
      expect(svc.isSupportedNotifier.value, isTrue);
      expect(svc.isSupported, isTrue);
      expect(fired, 1);

      // Re-initializing must NOT fire the notifier again — the
      // probe result is cached.
      await svc.initialize();
      expect(fired, 1);
    });

    test(
      'isSupportedNotifier flips to false on a platform that returns false',
      () async {
        platform.supported = false;
        final svc = buildService();
        await svc.initialize();
        expect(svc.isSupportedNotifier.value, isFalse);
        expect(svc.isSupported, isFalse);
      },
    );
  });
}
