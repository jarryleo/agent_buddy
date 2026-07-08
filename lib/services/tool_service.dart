import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

/// Thrown by [ToolService] when a tool call fails. Carries a short,
/// human-readable message that is both shown to the AI (so it can
/// recover / retry) and surfaced in the chat UI as a failed tool call.
class ToolException implements Exception {
  ToolException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ToolService {
  final http.Client _client = http.Client();

  /// Fetches the content of [url] and returns it as plain text.
  /// Throws [ToolException] on any failure (bad URL, network error,
  /// non-2xx HTTP, empty body).
  Future<String> fetchWeb(String url, {int maxLength = 8000}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw ToolException('invalid URL: $url');
    }
    final http.Response resp;
    try {
      resp = await _client
          .get(uri, headers: {
            'User-Agent':
                'Mozilla/5.0 (compatible; AgentBuddy/1.0; +https://agent.buddy)',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          })
          .timeout(const Duration(seconds: 20));
    } on ToolException {
      rethrow;
    } catch (e) {
      throw ToolException(e.toString());
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ToolException('HTTP ${resp.statusCode}');
    }
    final contentType = resp.headers['content-type'] ?? '';
    if (contentType.contains('application/json')) {
      var text = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(utf8.decode(resp.bodyBytes)));
      if (text.length > maxLength) {
        text = '${text.substring(0, maxLength)}\n...(truncated)';
      }
      return text;
    }
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final doc = html_parser.parse(body);
    for (final el in doc.querySelectorAll('script, style, noscript, svg')) {
      el.remove();
    }
    String text = doc.body?.text ?? doc.documentElement?.text ?? '';
    text = text
        .replaceAll(RegExp(r'\s+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
    text = text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
    if (text.length > maxLength) {
      text =
          '${text.substring(0, maxLength)}\n...(truncated, total ${text.length} chars)';
    }
    if (text.isEmpty) {
      throw ToolException('empty page content');
    }
    return text;
  }

  void dispose() {
    _client.close();
  }

  /// Returns the current local date/time as a JSON string with multiple
  /// formats so the model can pick whichever is convenient. Format:
  /// ```json
  /// {
  ///   "local": "2026-07-08 14:30:00",
  ///   "iso_local": "2026-07-08T14:30:00.123",
  ///   "iso_utc": "2026-07-08T06:30:00.123Z",
  ///   "unix": 1751961000,
  ///   "unix_millis": 1751961000123,
  ///   "timezone_offset_minutes": 480,
  ///   "timezone_name": "China Standard Time"
  /// }
  /// ```
  Future<String> currentTime() async {
    final now = DateTime.now();
    final offsetMinutes = now.timeZoneOffset.inMinutes;
    final localStr =
        '${_four(now.year)}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final isoLocal = now.toIso8601String();
    final isoUtc = now.toUtc().toIso8601String();
    final unix = now.millisecondsSinceEpoch ~/ 1000;
    final unixMillis = now.millisecondsSinceEpoch;
    final payload = {
      'local': localStr,
      'iso_local': isoLocal,
      'iso_utc': isoUtc,
      'unix': unix,
      'unix_millis': unixMillis,
      'timezone_offset_minutes': offsetMinutes,
      'timezone_name': now.timeZoneName,
    };
    return jsonEncode(payload);
  }

  String _four(int n) => n.toString().padLeft(4, '0');
  String _two(int n) => n.toString().padLeft(2, '0');

  /// Returns a JSON snapshot of the local desktop environment so the
  /// model can pick the right commands before calling `run_command`
  /// (e.g. `ipconfig` on Windows vs `ip addr` on Linux, `/Users/x`
  /// vs `C:\Users\x`). Includes:
  ///   os, os_version, arch, hostname, user, home, shell, cwd,
  ///   num_processors, kernel
  /// Only available on macOS / Windows / Linux; throws [ToolException]
  /// on web and mobile.
  Future<String> getEnvironment() async {
    if (kIsWeb) {
      throw ToolException('get_environment is not supported on web');
    }
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw ToolException(
        'get_environment is only supported on desktop (macOS / Windows / Linux)',
      );
    }

    // `dart:io` already gives us a lot; the kernel string and arch
    // (on Unix) need a one-shot command. Cap each command at 5s so
    // a stuck shell doesn't hang the whole tool call.
    Future<String> runShell(
      String executable,
      List<String> args,
    ) async {
      try {
        final result = await Process.run(executable, args, runInShell: true)
            .timeout(const Duration(seconds: 5));
        return result.stdout.toString().trim();
      } catch (_) {
        return '';
      }
    }

    final isWin = Platform.isWindows;

    // Kernel: `uname -a` on Unix, `ver` on Windows. If the command
    // fails, fall back to whatever dart:io already knows.
    final kernel = await runShell(
      isWin ? 'cmd' : 'uname',
      isWin ? ['/c', 'ver'] : ['-a'],
    );

    // Arch: env var on Windows, `uname -m` on Unix.
    final arch = isWin
        ? (Platform.environment['PROCESSOR_ARCHITECTURE'] ??
            (await runShell('cmd', ['/c', 'echo %PROCESSOR_ARCHITECTURE%'])))
        : (await runShell('uname', ['-m']));

    return jsonEncode({
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'arch': arch.isEmpty ? 'unknown' : arch,
      'hostname': Platform.localHostname,
      'user': Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          'unknown',
      'home': Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '',
      'shell': Platform.environment['SHELL'] ??
          Platform.environment['COMSPEC'] ??
          '',
      'cwd': Directory.current.path,
      'num_processors': Platform.numberOfProcessors,
      'kernel': kernel.isEmpty ? Platform.operatingSystemVersion : kernel,
    });
  }

  /// Runs [command] through the system shell and returns the captured
  /// stdout, stderr and exit code as a JSON string:
  /// ```json
  /// {"exit_code": 0, "stdout": "...", "stderr": "..."}
  /// ```
  /// Only available on macOS / Windows / Linux; throws [ToolException]
  /// on web and mobile. If the command doesn't finish within
  /// [timeoutSeconds] the underlying process is killed and a timeout
  /// error is thrown.
  Future<String> runCommand({
    required String command,
    String? cwd,
    int timeoutSeconds = 30,
  }) async {
    if (kIsWeb) {
      throw ToolException('run_command is not supported on web');
    }
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      throw ToolException(
        'run_command is only supported on desktop (macOS / Windows / Linux)',
      );
    }
    if (command.trim().isEmpty) {
      throw ToolException('command must not be empty');
    }

    // Use Process.start (not Process.run) so we can kill the child
    // when the user-configured timeout fires — otherwise a runaway
    // command (e.g. `sleep 9999`) would keep eating CPU past the
    // timeout.
    final Process process;
    try {
      process = await Process.start(
        command,
        const [],
        workingDirectory: cwd,
        runInShell: true,
      );
    } catch (e) {
      throw ToolException('failed to start command: $e');
    }

    // Use the system's encoding rather than forcing UTF-8: macOS and
    // Linux default to UTF-8 (so this is a no-op there), but Windows
    // uses its OEM code page — GBK on Chinese systems, CP437 on
    // Western systems, etc. Decoding GBK/CP437 bytes with UTF-8
    // produces mojibake at best and `FormatException` at worst, and
    // the previous code was silently swallowing the latter via
    // `onError: (_) {}` — leaving the AI to wonder why `dir` and
    // `ipconfig` returned empty stdout.
    final decoder = systemEncoding.decoder;
    // Use `toList()` rather than `listen()` and write to a list. The
    // latter races: `await process.exitCode` can resolve before the
    // last chunked bytes are delivered to the listener, and the
    // function returns with a half-drained stdout. `toList()` returns
    // a Future that only completes when the stream is closed, so
    // awaiting it after the exit code guarantees we have every byte.
    final stdoutFuture = process.stdout.transform(decoder).toList();
    final stderrFuture = process.stderr.transform(decoder).toList();

    final exitCode = await process.exitCode.timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () {
        process.kill();
        throw TimeoutException('command timed out after ${timeoutSeconds}s');
      },
    );

    final stdout = (await stdoutFuture).join();
    final stderr = (await stderrFuture).join();

    final payload = jsonEncode({
      'exit_code': exitCode,
      'stdout': stdout,
      'stderr': stderr,
    });
    // Surface a non-zero exit as a *failure* via ToolException, so:
    //  - the tool card flips to "失败" instead of the misleading
    //    "成功 32 毫秒" we previously showed for `ip addr show`
    //    on Windows, and
    //  - the AI sees the "Error: " prefix in the tool result and
    //    is much more likely to acknowledge the failure to the
    //    user instead of silently emitting `[DONE]`. The full
    //    JSON is preserved inside the exception message so the
    //    model can still parse exit_code / stdout / stderr.
    if (exitCode != 0) {
      throw ToolException(payload);
    }
    return payload;
  }
}
