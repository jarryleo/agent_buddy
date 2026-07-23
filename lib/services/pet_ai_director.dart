import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../models/message.dart';
import '../models/pet.dart';
import '../providers/chat_provider.dart';
import '../providers/settings_provider.dart';
import '../services/api_service.dart';
import '../services/local_llm_service.dart';
import '../services/pet_service.dart';
import '../services/pet_window_controller.dart';

/// Returns a `[HH:MM:SS.mmm]` prefix for log lines. Used by
/// the director + logger so the AI request cycle is easy to
/// correlate with the rest of the chat / pet log.
String _stamp(String message) {
  final now = DateTime.now();
  final hh = now.hour.toString().padLeft(2, '0');
  final mm = now.minute.toString().padLeft(2, '0');
  final ss = now.second.toString().padLeft(2, '0');
  final ms = now.millisecond.toString().padLeft(3, '0');
  return '[$hh:$mm:$ss.$ms] $message';
}

/// Cross-platform orchestration engine for the "AI-driven
/// desktop pet" feature. The director watches three
/// signals:
///
///   * the master's `showDesktopPet` toggle (we need a live
///     pet window to act on),
///   * the secondary `petAiBehaviorEnabled` toggle (opt-in),
///   * the main chat's `sending` flag (the director pauses
///     while the user is in the middle of a turn).
///
/// When all three say "go" — pet on, AI behavior on, chat
/// idle — the director arms a 1-minute idle timer. The first
/// time that timer fires (with chat still idle) the director
/// asks the active model to plan a list of behaviors. The
/// response is a JSON timeline; the director caches it,
/// schedules each entry at its offset, and triggers
/// `playOneShot` / `run_*` / `showText` through the
/// existing [PetWindowController] bridges. Once the timeline
/// finishes, the director loops back to the idle timer and
/// asks the model again.
///
/// The AI call is dispatched through the same `ApiService` /
/// `LocalLlmService` that the main chat uses, but with a
/// separate, ephemeral conversation — so the model never
/// sees the main chat's history and the main chat never sees
/// the director's private request. The user is unaware the
/// call is happening.
///
/// If the model's response is malformed or the JSON can't be
/// parsed, the director backs off for one minute and asks
/// again, repeating indefinitely until either the user
/// disables the toggle or the model produces a usable plan.
class PetAiDirector {
  PetAiDirector({
    required SettingsProvider settings,
    required ChatProvider chatProvider,
    required PetAiTransport transport,
    required PetService petService,
    required PetWindowController? petWindow,
    required String Function() systemLocaleCode,
    required PetAiLogger logger,
  }) : _settings = settings,
       _chatProvider = chatProvider,
       _transport = transport,
       _petService = petService,
       _petWindow = petWindow,
       _systemLocaleCode = systemLocaleCode,
       _logger = logger;

  final SettingsProvider _settings;
  final ChatProvider _chatProvider;
  final PetAiTransport _transport;
  final PetService _petService;
  final PetWindowController? _petWindow;
  final String Function() _systemLocaleCode;
  final PetAiLogger _logger;

  // ---- internal state ----

  Timer? _idleTimer;
  Timer? _resumeTimer;
  Timer? _orchestrationMasterTimer;
  final List<Timer> _behaviorTimers = [];

  bool _disposed = false;
  bool _isRunningPlan = false;
  bool _isMainWindowBusy = false;
  bool _petVisible = false;
  bool _enabled = false;
  bool _lastRequestInFlight = false;

  VoidCallback? _settingsSub;
  VoidCallback? _busySub;

  /// Wires the director up to the live settings / chat
  /// signals. Idempotent. Call once from `mainApp` after the
  /// collaborators are ready.
  void start() {
    if (_disposed) return;
    _enabled = _settings.petAiBehaviorEnabled;
    _petVisible = _settings.showDesktopPet;
    _isMainWindowBusy = _chatProvider.isUserInteracting;
    _settingsSub = _onSettingsTick;
    _settings.addListener(_settingsSub!);
    _busySub = _onChatBusyTick;
    _chatProvider.addListener(_busySub!);
    _log(
      'started '
      '(enabled=$_enabled, petVisible=$_petVisible, '
      'chatBusy=$_isMainWindowBusy).',
    );
    _evaluate();
  }

  /// Tears down timers + listeners. After `dispose` the
  /// instance is unusable; the caller should drop the
  /// reference.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelAllTimers();
    if (_settingsSub != null) {
      _settings.removeListener(_settingsSub!);
      _settingsSub = null;
    }
    if (_busySub != null) {
      _chatProvider.removeListener(_busySub!);
      _busySub = null;
    }
    // Best-effort: ask the pet to drop any in-flight move.
    // ignore: discarded_futures
    _petWindow?.cancelMove();
  }

  void _onSettingsTick() {
    if (_disposed) return;
    final enabled = _settings.petAiBehaviorEnabled;
    final petVisible = _settings.showDesktopPet;
    if (enabled != _enabled) {
      _enabled = enabled;
      if (!enabled) {
        _cancelAllTimers();
        _orchestrationMasterTimer?.cancel();
        _orchestrationMasterTimer = null;
        _isRunningPlan = false;
      }
      _log(
        'settings tick — '
        'petAiBehaviorEnabled=$enabled, petVisible=$petVisible.',
      );
    }
    if (petVisible != _petVisible) {
      _petVisible = petVisible;
    }
    _evaluate();
  }

  void _onChatBusyTick() {
    if (_disposed) return;
    // Listen to `isUserInteracting` rather than just
    // `sending`. This combines two conditions:
    //   * the AI is currently generating a response
    //     (`_chatProvider._sending`), and
    //   * the user has typed or focused the chat input
    //     within the last `ChatProvider._kUserInteractionWindow`.
    // Either one pauses the AI-orchestrated pet timeline so
    // a moving pet can't steal focus from the input field.
    final busy = _chatProvider.isUserInteracting;
    if (busy == _isMainWindowBusy) return;
    _isMainWindowBusy = busy;
    if (busy && _isRunningPlan) {
      // Show the user why the pet just stopped — without
      // this the timeline silently freezes mid-move when
      // they click back into the chat input.
      _log(
        'main window became busy — pausing orchestration '
        'and cancelling any in-flight pet movement.',
      );
    }
    _evaluate();
  }

  /// Main state-machine entry. Decides whether to (a) arm
  /// the idle timer, (b) cancel everything, or (c) stay in
  /// the current state.
  void _evaluate() {
    if (_disposed) return;
    final canRun = _enabled && _petVisible && !_isMainWindowBusy;
    if (!canRun) {
      _cancelIdleTimer();
      _cancelResumeTimer();
      if (_isRunningPlan) {
        _pauseOrchestration();
      }
      return;
    }
    if (_isRunningPlan) {
      // Resume path: if the user just went idle (chat
      // busy false but we're already paused), wait 1 min
      // before resuming the timeline.
      _scheduleResumeTimer();
      return;
    }
    _scheduleIdleTimer();
  }

  void _scheduleIdleTimer() {
    _cancelIdleTimer();
    _idleTimer = Timer(_kIdleBeforeFirstPlan, _onIdleFired);
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _scheduleResumeTimer() {
    _cancelResumeTimer();
    _resumeTimer = Timer(_kIdleBeforeResume, _onResumeIdleFired);
  }

  void _cancelResumeTimer() {
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }

  void _cancelAllTimers() {
    _cancelIdleTimer();
    _cancelResumeTimer();
    for (final t in _behaviorTimers) {
      t.cancel();
    }
    _behaviorTimers.clear();
  }

  Future<void> _onIdleFired() async {
    if (_disposed) return;
    if (!_enabled || !_petVisible || _isMainWindowBusy) return;
    _cancelIdleTimer();
    if (_petWindow == null) return;
    _log('idle fired — requesting a new plan.');
    await _requestNextPlan();
  }

  Future<void> _onResumeIdleFired() async {
    if (_disposed) return;
    if (!_enabled || !_petVisible || _isMainWindowBusy) return;
    _cancelResumeTimer();
    _resumeOrchestration();
  }

  /// Timestamp-prefixed logger. Every PetAiDirector log
  /// line starts with `[HH:MM:SS.mmm]` so the user can
  /// correlate the AI request cycle with the rest of the
  /// pet / chat log without having to fish for ordering.
  void _log(String message) {
    debugPrint(_stamp('PetAiDirector: $message'));
  }

  Future<void> _requestNextPlan() async {
    if (_lastRequestInFlight) return;
    _lastRequestInFlight = true;
    try {
      final pet = await _findActivePet();
      final lang = _resolveLanguage();
      final timeline = await _requestPlanFromModel(pet: pet, lang: lang);
      _logger.logPlan(timeline);
      final behaviors = parseTimeline(timeline);
      if (behaviors.isEmpty) {
        // Bad JSON — back off and retry.
        _log(
          'model returned an empty timeline — '
          'backing off ${_kIdleBeforeFirstPlan.inSeconds}s.',
        );
        _scheduleIdleTimer();
        return;
      }
      _log(
        'timeline has ${behaviors.length} entries; '
        'orchestration starts in <1s.',
      );
      _startOrchestration(behaviors);
    } catch (e, st) {
      _log('request failed: $e\n$st');
      _scheduleIdleTimer();
    } finally {
      _lastRequestInFlight = false;
    }
  }

  Future<Pet?> _findActivePet() async {
    final pets = await _petService.ensureReady();
    final id = _settings.activePetId;
    if (id == null || id.isEmpty) {
      return pets.isNotEmpty ? pets.first : null;
    }
    for (final p in pets) {
      if (p.id == id) return p;
    }
    return null;
  }

  String _resolveLanguage() {
    final raw = _settings.localeCode;
    final code = raw == 'system' || raw.isEmpty ? _systemLocaleCode() : raw;
    return code.startsWith('zh') ? 'zh' : 'en';
  }

  /// Send the orchestration request to the active model via
  /// the supplied [PetAiTransport]. The transport is the
  /// production `ApiService` / `LocalLlmService` in mainApp;
  /// tests inject a scripted stream. We pass a `null` tool
  /// executor so the model can't accidentally call any tool
  /// — the director only wants a JSON plan.
  Future<String> _requestPlanFromModel({
    required Pet? pet,
    required String lang,
  }) async {
    final system = _buildSystemPrompt(pet: pet, lang: lang);
    final user = _buildUserPrompt(pet: pet, lang: lang);
    final messages = [
      ChatRequestMessage(role: MessageRole.user, content: user),
    ];
    final buf = StringBuffer();
    await for (final ev in _transport.stream(
      systemPrompts: [system],
      messages: messages,
    )) {
      switch (ev.type) {
        case 'content':
          if (ev.contentDelta != null) buf.write(ev.contentDelta);
          break;
        case 'error':
          throw StateError('model error: ${ev.error}');
      }
    }
    return buf.toString();
  }

  String _buildSystemPrompt({required Pet? pet, required String lang}) {
    final petName = pet?.displayName ?? 'the pet';
    final petDescription =
        pet?.description ?? 'A friendly little desktop companion';
    return 'You are the silent director of a small desktop pet '
        'named "$petName" shown on top of the user\'s main app. '
        'The pet is idle and the user is not interacting with the '
        'main app. Your job is to plan a short, in-character '
        'sequence of behaviors to make the pet feel alive.\n'
        '\n'
        '## About the pet\n'
        '$petDescription\n'
        '\n'
        '## Output language\n'
        'Speak in the user\'s app language (currently `$lang`). '
        'All `speak` text must be in `$lang`.\n'
        '\n'
        '## Available actions\n'
        'Each item is one behavior. Choose freely from the three '
        'action types below:\n'
        '- `move`: walk to a screen coordinate. The OS-level window '
        'is the pet itself; the pet cannot overlap with the screen '
        'edge. Coordinate space is the primary display in physical '
        'pixels (origin at top-left). The pet will pick a left/right '
        'run animation based on the frame delta and revert to idle '
        'when it stops.\n'
        '- `speak`: show a short speech bubble above the pet\'s '
        'head. Keep it to one sentence, in character, in `$lang`. '
        'The bubble auto-hides after ~10s.\n'
        '- `act`: play one short action once. Available actions: '
        '`waving`, `jumping`, `failed`. Other actions like `idle`, '
        '`run_left`, `run_right`, `waiting`, `running`, `review` '
        'are ambient and should NOT be played here. `jumping` may '
        'repeat up to 5 times via the `repeats` field; `waving` '
        'and `failed` are always 1.\n'
        '\n'
        '## Output format\n'
        'Reply with a STRICT JSON array. No prose, no markdown '
        'fences, no comments. Each item has: `time` (MM:SS offset '
        'from when this message was received — e.g. "00:15" means '
        'fire 15 seconds in), `type` (`move` / `speak` / `act`), '
        'plus the type-specific fields below.\n'
        '\n'
        'Field schema:\n'
        '- move: `x` (int, screen pixel), `y` (int, screen pixel), '
        '`speed` (int, pixels per second, 30–240, default 80)\n'
        '- speak: `text` (string, one short sentence)\n'
        '- act: `name` (one of `waving` / `jumping` / `failed`), '
        '`repeats` (int, 1–5, default 1)\n'
        '\n'
        '## Constraints\n'
        '- At least 10 entries.\n'
        '- Total timeline must not exceed 5 minutes (300s).\n'
        '- Consecutive entries must be at least 10 seconds apart.\n'
        '- Coordinates must be inside the primary display and not '
        'overlap the screen edge — leave at least the pet\'s '
        'sprite width / height of margin.\n'
        '- Vary the actions; don\'t just walk continuously.\n'
        'The speech bubbles should reflect the pet\'s personality '
        'and current activity — what would this character say if '
        'they were gently wandering around while the user works?\n'
        '\n'
        'Your reply must be a single JSON array and nothing else.';
  }

  String _buildUserPrompt({required Pet? pet, required String lang}) {
    final petName = pet?.displayName ?? 'the pet';
    return 'Plan a 5-minute idle timeline for "$petName". '
        'Output language: $lang. Reply with a JSON array only.';
  }

  // -------- Parsing & validation --------

  /// Decode the raw model reply into a list of
  /// [PetBehavior]s. Tolerant: the model may wrap the array
  /// in markdown fences or include a brief preamble; we
  /// extract the first balanced JSON array we find. Returns
  /// an empty list when nothing usable can be parsed.
  ///
  /// The actual parsing lives in [parsePetTimeline] (a pure
  /// top-level function) so the unit tests can exercise the
  /// JSON grammar without instantiating the full director.
  @visibleForTesting
  List<PetBehavior> parseTimeline(String raw) => parsePetTimeline(raw);

  // -------- Orchestration runtime --------

  void _startOrchestration(List<PetBehavior> plan) {
    _orchestrationMasterTimer?.cancel();
    final baseTime = DateTime.now();
    _isRunningPlan = true;
    for (final t in _behaviorTimers) {
      t.cancel();
    }
    _behaviorTimers.clear();
    for (final behavior in plan) {
      final remaining =
          Duration(seconds: behavior.offsetSeconds) -
          DateTime.now().difference(baseTime);
      final timer = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        () => _runBehavior(behavior),
      );
      _behaviorTimers.add(timer);
    }
    // Master timer: when the last entry has likely fired,
    // loop back to the idle arm path.
    final lastOffset = plan.last.offsetSeconds;
    _orchestrationMasterTimer = Timer(
      Duration(seconds: lastOffset + 5),
      _onPlanFinished,
    );
  }

  void _pauseOrchestration() {
    for (final t in _behaviorTimers) {
      t.cancel();
    }
    _behaviorTimers.clear();
    _orchestrationMasterTimer?.cancel();
    _orchestrationMasterTimer = null;
    // Best-effort: cancel any in-flight move so the pet
    // stops where it is.
    // ignore: discarded_futures
    _petWindow?.cancelMove();
  }

  void _resumeOrchestration() {
    if (!_isRunningPlan) return;
    // After a 1-minute idle gap the user is back to doing
    // nothing — the cleanest resume is to ask the model for
    // a fresh plan. The previous plan's slots have all
    // either already fired or been skipped while we were
    // paused, so re-running it would be stale.
    _isRunningPlan = false;
    _lastRequestInFlight = false;
    _requestNextPlan();
  }

  void _onPlanFinished() {
    if (_disposed) return;
    _isRunningPlan = false;
    _orchestrationMasterTimer = null;
    if (!_enabled || !_petVisible || _isMainWindowBusy) return;
    _scheduleIdleTimer();
  }

  Future<void> _runBehavior(PetBehavior behavior) async {
    if (_disposed || _petWindow == null) return;
    if (_isMainWindowBusy) return;
    switch (behavior.type) {
      case PetBehaviorType.move:
        final x = behavior.raw['x'] as double;
        final y = behavior.raw['y'] as double;
        final speed = behavior.raw['speed'] as double;
        await _petWindow.moveTo(x: x, y: y, speed: speed);
        break;
      case PetBehaviorType.speak:
        final text = behavior.raw['text'] as String;
        await _petWindow.showText(text);
        break;
      case PetBehaviorType.act:
        final name = behavior.raw['name'] as String;
        final repeats = behavior.raw['repeats'] as int;
        await _playActWithRepeats(name, repeats);
        break;
    }
  }

  Future<void> _playActWithRepeats(String name, int repeats) async {
    if (repeats <= 1) {
      await _petWindow?.playOneShot(name);
      return;
    }
    // `jumping` is the only action that repeats. Chain
    // one-shot invocations on a fixed cadence (~1.2s — the
    // 5-frame clip at 5 fps lasts ~1.0s). Other actions
    // collapse to a single one-shot.
    if (name == 'jumping') {
      _jumpRepeatsInFlight = repeats;
      _scheduleJumpRepeats(0);
      return;
    }
    await _petWindow?.playOneShot(name);
  }

  int _jumpRepeatsInFlight = 0;

  void _scheduleJumpRepeats(int done) {
    if (_disposed) return;
    if (done >= _jumpRepeatsInFlight) return;
    _petWindow?.playOneShot('jumping');
    Timer(const Duration(milliseconds: 1200), () {
      _scheduleJumpRepeats(done + 1);
    });
  }
}

/// One step in an AI-orchestrated pet timeline.
@immutable
class PetBehavior {
  const PetBehavior({
    required this.offsetSeconds,
    required this.type,
    required this.raw,
  });

  final int offsetSeconds;
  final PetBehaviorType type;
  final Map<String, dynamic> raw;
}

enum PetBehaviorType { move, speak, act }

// -------- Pure parsing helpers --------

/// Pure top-level parser: takes the raw model reply (which may
/// include a markdown preamble / code fences), extracts the
/// first balanced JSON array, and validates each entry. The
/// result is either a usable timeline (>= 10 entries, sorted
/// in offset order, each at least 10s apart from the previous)
/// or an empty list when the reply is unusable.
///
/// Tolerant of the most common malformations our model exhibits
/// in practice:
///   * missing trailing `]` (the model truncated the reply)
///   * trailing comma before the (missing) `]`
///   * prose preamble / markdown code fences
///
/// The director consumes this function through [PetAiDirector]
/// and retries with a 1-minute back-off when the result is
/// empty. Tests cover the JSON grammar directly without
/// instantiating the director.
List<PetBehavior> parsePetTimeline(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];
  final cleaned = _stripMarkdownFences(trimmed);
  final candidates = _candidateArrayTexts(cleaned);
  for (final candidate in candidates) {
    final decoded = _tryDecode(candidate);
    if (decoded is List) {
      final out = _buildBehaviors(decoded);
      if (out.length >= _kMinBehaviorsPerPlan) return out;
    }
  }
  return const [];
}

/// Decode a JSON string, gracefully tolerating a missing
/// trailing `]` and a trailing comma. Returns the decoded
/// value on success, or `null` when the input is unrecoverable.
dynamic _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    // Fall through to the recovery path.
  }
  // Recovery: try to close the array manually. If the
  // trailing character is a comma, strip it first.
  var mutated = text.trimRight();
  if (mutated.endsWith(',')) {
    mutated = mutated.substring(0, mutated.length - 1);
  }
  if (mutated.endsWith('}')) {
    mutated = '$mutated]';
  }
  try {
    return jsonDecode(mutated);
  } catch (_) {
    return null;
  }
}

/// Build candidate array substrings to try, in priority order:
///   1. A well-formed [ ... ] slice from the first '[' to
///      its matching ']' (the common case).
///   2. The slice from the first '[' to the end of the input
///      (the model truncated the reply and forgot the closing
///      ']'). The decode path will append the missing bracket.
List<String> _candidateArrayTexts(String raw) {
  final out = <String>[];
  final wellFormed = _extractFirstJsonArray(raw);
  if (wellFormed != null) out.add(wellFormed);
  final start = raw.indexOf('[');
  if (start < 0) return out;
  // The well-formed slice already covers the [ ... ] case.
  // Only add the truncated slice if it differs from the
  // well-formed one (i.e. the array really was unclosed).
  final truncated = raw.substring(start).trimRight();
  if (truncated != wellFormed && truncated.isNotEmpty) {
    out.add(truncated);
  }
  return out;
}

List<PetBehavior> _buildBehaviors(List<dynamic> decoded) {
  final out = <PetBehavior>[];
  int? lastSeconds;
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final normalized = entry.cast<String, dynamic>();
    final behavior = _parseBehavior(normalized);
    if (behavior == null) continue;
    if (behavior.offsetSeconds < 0) continue;
    if (behavior.offsetSeconds > _kMaxTimelineSeconds) continue;
    if (lastSeconds != null &&
        behavior.offsetSeconds - lastSeconds < _kMinGapSeconds) {
      // Auto-pad to enforce the min gap rule so a model
      // that misjudges the spacing still produces a
      // usable timeline.
      out.add(
        PetBehavior(
          offsetSeconds: lastSeconds + _kMinGapSeconds,
          type: behavior.type,
          raw: behavior.raw,
        ),
      );
      lastSeconds = lastSeconds + _kMinGapSeconds;
    } else {
      out.add(behavior);
      lastSeconds = behavior.offsetSeconds;
    }
  }
  return out;
}

String _stripMarkdownFences(String raw) {
  var text = raw;
  if (text.startsWith('```')) {
    final newline = text.indexOf('\n');
    if (newline >= 0) text = text.substring(newline + 1);
    if (text.endsWith('```')) {
      text = text.substring(0, text.length - 3);
    }
  }
  return text.trim();
}

String? _extractFirstJsonArray(String raw) {
  final start = raw.indexOf('[');
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escape = false;
  for (var i = start; i < raw.length; i++) {
    final c = raw[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (c == r'\') {
      escape = true;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (c == '[') depth++;
    if (c == ']') {
      depth--;
      if (depth == 0) return raw.substring(start, i + 1);
    }
  }
  return null;
}

PetBehavior? _parseBehavior(Map<String, dynamic> json) {
  final offsetSeconds = _parseTime(json['time']);
  if (offsetSeconds == null) return null;
  final type = (json['type'] as String?)?.trim().toLowerCase();
  if (type == 'move') {
    final x = (json['x'] as num?)?.toDouble();
    final y = (json['y'] as num?)?.toDouble();
    final speed = (json['speed'] as num?)?.toDouble() ?? 80.0;
    if (x == null || y == null) return null;
    return PetBehavior(
      offsetSeconds: offsetSeconds,
      type: PetBehaviorType.move,
      raw: <String, dynamic>{'x': x, 'y': y, 'speed': speed.clamp(30.0, 240.0)},
    );
  }
  if (type == 'speak') {
    final text = (json['text'] as String?)?.trim() ?? '';
    if (text.isEmpty) return null;
    return PetBehavior(
      offsetSeconds: offsetSeconds,
      type: PetBehaviorType.speak,
      raw: <String, dynamic>{'text': text},
    );
  }
  if (type == 'act') {
    final rawName = (json['name'] as String?)?.trim().toLowerCase();
    final repeats = (json['repeats'] as num?)?.toInt() ?? 1;
    final allowed = <String>{
      'waving',
      'jumping',
      'failed',
      'wave',
      'jump',
      'fail',
      'failure',
    };
    if (rawName == null || !allowed.contains(rawName)) return null;
    // Normalise legacy aliases to the canonical petdex name
    // so the window controller passes a known string to
    // `playOneShot`. Without this the renderer would still
    // accept any name, but the parser now writes the
    // canonical form so consumers don't have to re-normalise.
    final name = switch (rawName) {
      'wave' => 'waving',
      'jump' => 'jumping',
      'fail' || 'failure' => 'failed',
      _ => rawName,
    };
    final clamped = repeats < 1 ? 1 : (repeats > 5 ? 5 : repeats);
    return PetBehavior(
      offsetSeconds: offsetSeconds,
      type: PetBehaviorType.act,
      raw: <String, dynamic>{'name': name, 'repeats': clamped},
    );
  }
  return null;
}

int? _parseTime(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.contains(':')) {
      final parts = s.split(':');
      if (parts.length != 2) return null;
      final m = int.tryParse(parts[0].trim()) ?? -1;
      final sec = int.tryParse(parts[1].trim()) ?? -1;
      if (m < 0 || sec < 0) return null;
      return m * 60 + sec;
    }
    return int.tryParse(s);
  }
  return null;
}

/// Tunables. Kept as top-level constants instead of being
/// injected as parameters so the production wiring stays
/// trivial. The unit tests assert these.
const Duration _kIdleBeforeFirstPlan = Duration(minutes: 1);
const Duration _kIdleBeforeResume = Duration(minutes: 1);
const int _kMinBehaviorsPerPlan = 10;
const int _kMaxTimelineSeconds = 5 * 60;
const int _kMinGapSeconds = 10;

// -------- Test seams --------

/// The streaming call the director uses to ask the model
/// for a new timeline. Production wires this to either
/// `ApiService.streamChat` (cloud) or
/// `LocalLlmService.streamChat` (local GGUF). Tests inject
/// scripted streams.
abstract class PetAiTransport {
  Stream<StreamEvent> stream({
    required List<String> systemPrompts,
    required List<ChatRequestMessage> messages,
  });
}

/// Logger for the model-returned JSON. Production writes
/// to `dart:developer.log` so the console shows the raw
/// payload.
abstract class PetAiLogger {
  void logPlan(String json);
}

/// Production transport. Routes the request to the
/// currently configured cloud provider (or local GGUF).
/// Resolves the live `SettingsProvider` snapshot on every
/// call so the director always sees the user's current
/// selection.
class DefaultPetAiTransport implements PetAiTransport {
  DefaultPetAiTransport({
    required this.api,
    required this.localLlm,
    required this.settings,
  });

  final ApiService api;
  final LocalLlmService localLlm;
  final SettingsProvider settings;

  @override
  Stream<StreamEvent> stream({
    required List<String> systemPrompts,
    required List<ChatRequestMessage> messages,
  }) {
    if (settings.useLocalModel) {
      final lp = settings.activeLocalProvider;
      if (lp == null) {
        throw StateError(
          'PetAiDirector: no active local provider configured. '
          'Set up a local model on the settings tab first.',
        );
      }
      return localLlm.streamChat(
        provider: lp,
        systemPrompts: systemPrompts,
        messages: messages,
        // Empty tool list — the director only wants a JSON
        // plan and explicitly forbids the model from calling
        // any tool.
        tools: const [],
        // `null` forces a fresh reset+seed on the local
        // engine so the director's conversation never
        // bleeds into the main chat's next turn.
        boundSessionId: null,
      );
    }
    final p = settings.activeProvider;
    if (p == null) {
      throw StateError('PetAiDirector: no active cloud provider configured.');
    }
    final modelId =
        p.selectedModel ?? (p.models.isNotEmpty ? p.models.first : '');
    if (modelId.isEmpty) {
      throw StateError('PetAiDirector: active provider has no model selected.');
    }
    return api.streamChat(
      provider: p,
      model: modelId,
      messages: messages,
      systemPrompts: systemPrompts,
    );
  }
}

/// Production logger. Writes to `dart:developer.log` so the
/// JSON shows up in the console / DevTools.
class StdoutPetAiLogger implements PetAiLogger {
  @override
  void logPlan(String json) {
    final stamped = _stamp('model returned timeline:\n$json');
    developer.log(stamped, name: 'PetAiDirector');
    debugPrint(stamped);
  }
}
