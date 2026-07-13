import 'dart:async';
import 'dart:convert';

import 'mcp_service.dart' show McpException;

/// Long-lived line reader over a stdio process's stdout.
///
/// Subscribes exactly once to the underlying [Stream] and dispatches
/// incoming newline-delimited JSON-RPC responses by id, so callers
/// can invoke [nextLine] multiple times against the same process
/// without tripping "stream has already been listened to" errors.
///
/// Non-matching lines (e.g. log noise, responses to a different
/// request id) are buffered and re-checked against future calls —
/// necessary because the MCP server may interleave notifications
/// with the responses we care about.
///
/// Pass the [stderrBuffer] shared with the process's stderr drain
/// so timeout / done error messages can include stderr context.
class McpStdioLineReader {
  McpStdioLineReader(
    Stream<List<int>> stdout, {
    required this.stderrBuffer,
  }) {
    _sub = stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: _onError,
          onDone: _onDone,
          cancelOnError: false,
        );
  }

  final StringBuffer stderrBuffer;
  late final StreamSubscription<String> _sub;
  final List<String> _buffered = [];
  Completer<String>? _waiting;
  String? _expectedId;
  bool _done = false;
  Object? _doneError;

  void _onLine(String line) {
    var trimmed = line.trimRight();
    if (trimmed.isEmpty) return;
    // Some servers emit a UTF-8 BOM on the very first line. Drop it
    // before the JSON parser sees the response.
    if (trimmed.codeUnitAt(0) == 0xFEFF) {
      trimmed = trimmed.substring(1);
    }
    if (trimmed.isEmpty) return;

    if (_waiting != null && _matchesExpected(trimmed, _expectedId)) {
      final c = _waiting!;
      _waiting = null;
      _expectedId = null;
      c.complete(trimmed);
      return;
    }
    _buffered.add(trimmed);
  }

  void _onError(Object e) {
    _done = true;
    _doneError = e;
    _flush();
  }

  void _onDone() {
    _done = true;
    _flush();
  }

  void _flush() {
    final c = _waiting;
    if (c == null) return;
    final wantedId = _expectedId;
    _waiting = null;
    _expectedId = null;

    while (_buffered.isNotEmpty) {
      final line = _buffered.removeAt(0);
      if (_matchesExpected(line, wantedId)) {
        c.complete(line);
        return;
      }
    }

    if (_doneError != null) {
      c.completeError(_doneError!);
    } else {
      final tail = stderrTail();
      c.completeError(
        McpException(
          'MCP 进程意外退出${tail.isNotEmpty ? " (stderr: $tail)" : ""}',
        ),
      );
    }
  }

  /// Wait for the next line from the process. If [expectedId] is
  /// set, the line's JSON `id` field must match; non-matching lines
  /// are kept in the internal buffer and re-checked against future
  /// calls. Times out after [timeout] with a descriptive
  /// [McpException] that includes the latest stderr tail.
  Future<String> nextLine({
    String? expectedId,
    required Duration timeout,
  }) {
    while (_buffered.isNotEmpty) {
      final line = _buffered.removeAt(0);
      if (_matchesExpected(line, expectedId)) {
        return Future.value(line);
      }
    }

    if (_done) {
      if (_doneError != null) return Future.error(_doneError!);
      return Future.error(
        McpException('MCP 进程意外退出${_stderrDetail()}'),
      );
    }

    final c = Completer<String>();
    _waiting = c;
    _expectedId = expectedId;
    return c.future.timeout(timeout, onTimeout: () {
      // A late line may have already drained `_waiting` between
      // the timer firing and this callback running — only clear
      // state if we're still the active waiter.
      if (identical(_waiting, c)) {
        _waiting = null;
        _expectedId = null;
      }
      throw McpException('MCP 请求超时(${timeout.inSeconds}s)${_stderrDetail()}');
    });
  }

  String stderrTail() => stderrBuffer.toString().trim();

  String _stderrDetail() {
    final tail = stderrTail();
    return tail.isNotEmpty ? ' stderr: $tail' : '';
  }

  bool _matchesExpected(String line, String? expectedId) {
    if (expectedId == null) return true;
    try {
      final data = jsonDecode(line) as Map<String, dynamic>;
      return data['id']?.toString() == expectedId;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() => _sub.cancel();
}
