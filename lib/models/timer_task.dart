enum TimerTaskStatus { pending, fired, cancelled }

/// A single in-app timer. Lives only while the app is running — no
/// persistence to disk (timers are lost on app kill by design, see
/// `TimerService` for the rationale).
///
/// Created by the AI via the `timer` tool, or by the user from the
/// Settings → Timers tab. When [fireAt] arrives, [TimerService]
/// emits a fire event that ChatProvider uses to kick off a new
/// chat turn (the AI then calls the `notification` tool).
class TimerTask {
  /// Stable id (`t_<µs>_<boxLength>`) used for tool-call result
  /// lookups and to dedupe updates from the model.
  final String id;

  /// Short, human-readable title shown in the timers tab and used
  /// as the system notification's title when the timer fires.
  final String label;

  /// The wall-clock instant at which the task fires. Always in
  /// local time; the scheduler handles the time-zone math.
  final DateTime fireAt;

  /// When the task was created. Used to sort the timers list
  /// (newest-first in the settings tab).
  final DateTime createdAt;

  /// Who created the task. `'ai'` for tool calls, `'user'` for
  /// hand-entered tasks in the settings tab. The AI sees its own
  /// `source` in tool results so it can reason about provenance.
  final String source;

  /// Optional free-form note attached by the creator. The AI is
  /// expected to put a short reminder message here (e.g. "drink
  /// water") so the [TimerService.fire] callback can hand it back
  /// to the model verbatim as part of the synthetic user message.
  final String prompt;

  /// Optional free-form hint telling the model what to do when the
  /// timer fires. Used by ChatProvider when composing the synthetic
  /// user message that drives the new turn. Defaults to a generic
  /// "call the notification tool to notify the user" hint.
  final String? actionHint;

  /// Current state. Pending tasks are still scheduled; fired /
  /// cancelled tasks stay in the list briefly so the UI can show
  /// the most-recent history before they're pruned.
  final TimerTaskStatus status;

  const TimerTask({
    required this.id,
    required this.label,
    required this.fireAt,
    required this.createdAt,
    required this.source,
    this.prompt = '',
    this.actionHint,
    this.status = TimerTaskStatus.pending,
  });

  TimerTask copyWith({
    String? label,
    DateTime? fireAt,
    String? prompt,
    String? actionHint,
    TimerTaskStatus? status,
  }) {
    return TimerTask(
      id: id,
      label: label ?? this.label,
      fireAt: fireAt ?? this.fireAt,
      createdAt: createdAt,
      source: source,
      prompt: prompt ?? this.prompt,
      actionHint: actionHint ?? this.actionHint,
      status: status ?? this.status,
    );
  }

  bool get isPending => status == TimerTaskStatus.pending;
  bool get isFired => status == TimerTaskStatus.fired;
  bool get isCancelled => status == TimerTaskStatus.cancelled;
  bool get isTerminal =>
      status == TimerTaskStatus.fired || status == TimerTaskStatus.cancelled;

  /// Time until the task fires, computed from [now]. Returns a
  /// negative duration if [now] is past [fireAt].
  Duration delayFrom(DateTime now) => fireAt.difference(now);

  /// Time until the task fires, computed from the current wall
  /// clock. Returns a negative duration if the fire time has
  /// already passed.
  Duration get delay => fireAt.difference(DateTime.now());

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'fireAtMs': fireAt.millisecondsSinceEpoch,
    'createdAtMs': createdAt.millisecondsSinceEpoch,
    'source': source,
    'prompt': prompt,
    if (actionHint != null) 'actionHint': actionHint,
    'status': status.name,
  };

  factory TimerTask.fromJson(Map<String, dynamic> json) {
    return TimerTask(
      id: json['id'] as String,
      label: json['label'] as String? ?? '',
      fireAt: DateTime.fromMillisecondsSinceEpoch(
        (json['fireAtMs'] as num?)?.toInt() ?? 0,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAtMs'] as num?)?.toInt() ?? 0,
      ),
      source: json['source'] as String? ?? 'user',
      prompt: json['prompt'] as String? ?? '',
      actionHint: json['actionHint'] as String?,
      status: TimerTaskStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => TimerTaskStatus.pending,
      ),
    );
  }
}
