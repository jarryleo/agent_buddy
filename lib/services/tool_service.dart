import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:hive_ce/hive.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/memory.dart';
import '../models/note.dart';
import '../models/task.dart';
import 'memory_repository.dart';
import 'platform/calendar_service.dart';
import 'platform/calendar_service_factory.dart';
import 'platform/location_service.dart';
import 'platform/location_service_factory.dart' as location_factory;
import 'platform/notes_service.dart';
import 'platform/reminders_service.dart';
import 'platform/reminders_service_factory.dart';
import 'platform/tasks_service.dart';

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
  ToolService({
    Box<Note>? notesBox,
    Box<Task>? tasksBox,
    Box<Memory>? memoriesBox,
    LocationServiceBuilder? locationBuilder,
    http.Client? httpClient,
  }) {
    if (notesBox != null) {
      _notes = NotesService()..open(preopened: notesBox);
    }
    if (tasksBox != null) {
      _tasks = TasksService()..open(preopened: tasksBox);
    }
    if (memoriesBox != null) {
      _memories = MemoryRepository()..open(preopened: memoriesBox);
    }
    _locationBuilder = locationBuilder;
    // If the caller injected a client (tests), we own it; otherwise
    // we own the one we create. dispose() closes only the one we own.
    if (httpClient != null) {
      _client = httpClient;
      _ownsClient = false;
    } else {
      _client = http.Client();
      _ownsClient = true;
    }
  }

  // HTTP client used by [fetchWeb]. Late + final so it can be
  // assigned exactly once in the constructor (including the
  // injected-client path used by tests).
  late final http.Client _client;
  // True iff [dispose] should close [_client] — false when the
  // client was injected by the caller (e.g. a test mock). Also
  // `late final` because we assign it inside a conditional in the
  // constructor body (assigning a plain `final` field in the
  // body is only allowed via initializers / initializing formals).
  late final bool _ownsClient;

  /// Lazily resolved on first calendar tool call. On non-mobile
  /// platforms [createCalendarService] returns a stub that throws
  /// [UnsupportedError] — `ToolException` catches that and surfaces
  /// a friendly "not supported" message to the model.
  CalendarService? _calendar;
  RemindersService? _reminders;
  NotesService? _notes;
  TasksService? _tasks;
  MemoryRepository? _memories;
  LocationServiceBuilder? _locationBuilder;
  LocationService? _location;

  CalendarService get calendar {
    _calendar ??= createCalendarService();
    return _calendar!;
  }

  RemindersService get reminders {
    _reminders ??= createRemindersService();
    return _reminders!;
  }

  NotesService get notes {
    _notes ??= NotesService()..open();
    return _notes!;
  }

  TasksService get tasks {
    _tasks ??= TasksService()..open();
    return _tasks!;
  }

  MemoryRepository get memories {
    _memories ??= MemoryRepository()..open();
    return _memories!;
  }

  LocationService get location {
    _location ??=
        (_locationBuilder ?? location_factory.createLocationService)();
    return _location!;
  }

  /// Per-URL page cache so that calling [fetchWeb] multiple times for
  /// the same URL — e.g. once to read the page and then again with
  /// different `linkText` values to follow links — does not re-fetch
  /// and re-parse the page each time. Bounded; the oldest entry is
  /// evicted when the cache exceeds [_fetchCacheMaxEntries].
  static const int _fetchCacheMaxEntries = 16;
  final Map<String, _FetchedPage> _fetchCache = <String, _FetchedPage>{};

  /// Fetches the content of [url] and returns a JSON envelope string.
  ///
  /// Default behavior: returns the page's title, plain text, and the
  /// number of links on the page. Link URLs are NOT included in the
  /// response (saves tokens). To navigate to a sub-page, pass
  /// [linkText] with the visible text of the link you want to follow
  /// — the tool resolves it against the page's `<a>` tags and adds
  /// the resolved URL to the response so the model can call
  /// `fetch_web(that_url)` to follow it.
  ///
  /// Parameters:
  ///   [url]          absolute URL to fetch
  ///   [linkText]     optional. If set, the tool looks up the first
  ///                  `<a>` on the page whose visible text matches
  ///                  (case-insensitive, normalized whitespace,
  ///                  exact match first, then substring) and adds
  ///                  `link_url` + `link_text_matched` to the
  ///                  response. Use this for multi-level navigation:
  ///                  `fetch_web(A)` → read text → `fetch_web(A,
  ///                  link_text='X')` → get URL for link X →
  ///                  `fetch_web(that_url)` → read sub-page.
  ///   [includeLinks] optional, default false. If true, an
  ///                  additional `links[]` array of `{text, url}`
  ///                  pairs is included (capped at 50). Use
  ///                  sparingly — it inflates the response.
  ///   [maxLength]    max characters of page text to include in the
  ///                  response. Default 8000.
  ///
  /// Throws [ToolException] on any failure (bad URL, network error,
  /// non-2xx HTTP, empty body).
  Future<String> fetchWeb(
    String url, {
    String? linkText,
    bool includeLinks = false,
    int maxLength = 8000,
  }) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      throw ToolException('invalid URL: $url');
    }
    if (linkText != null && linkText.trim().isEmpty) {
      linkText = null;
    }
    final normalizedKey = uri.toString();
    final cacheKey = '$normalizedKey|$maxLength';

    // Try the cache first. A page is reusable across calls as long
    // as maxLength matches (the truncated text length depends on
    // it) and the page parsed as HTML. JSON responses are
    // non-cached because they're typically not navigable.
    _FetchedPage? page = _fetchCache[cacheKey];
    if (page == null) {
      final http.Response resp;
      try {
        resp = await _client
            .get(
              uri,
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (compatible; AgentBuddy/1.0; +https://agent.buddy)',
                'Accept':
                    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
              },
            )
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
        var text = const JsonEncoder.withIndent(
          '  ',
        ).convert(jsonDecode(utf8.decode(resp.bodyBytes)));
        if (text.length > maxLength) {
          text = '${text.substring(0, maxLength)}\n...(truncated)';
        }
        // JSON responses are not cached: a model that wants to
        // navigate from a JSON blob doesn't have HTML links to
        // follow.
        return jsonEncode({
          'url': uri.toString(),
          'title': null,
          'text': text,
          'link_count': 0,
        });
      }
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final doc = html_parser.parse(body);
      for (final el in doc.querySelectorAll('script, style, noscript, svg')) {
        el.remove();
      }
      final title =
          doc
              .querySelector('title')
              ?.text
              .trim()
              .replaceAll(RegExp(r'\s+'), ' ') ??
          '';
      final rawText = doc.body?.text ?? doc.documentElement?.text ?? '';
      final cleanedText = _cleanWhitespace(rawText);
      final links = _extractLinks(doc, baseUri: uri);
      page = _FetchedPage(
        url: uri.toString(),
        title: title,
        cleanedText: cleanedText,
        links: links,
      );
      _fetchCache[cacheKey] = page;
      // Bound the cache; the oldest insertion is dropped first.
      if (_fetchCache.length > _fetchCacheMaxEntries) {
        final oldestKey = _fetchCache.keys.first;
        _fetchCache.remove(oldestKey);
      }
    }

    // Build the response envelope. Text is truncated per maxLength
    // (caching the full text lets us re-truncate at a different
    // length on a later call without re-fetching).
    var text = page.cleanedText;
    final truncated = text.length > maxLength;
    if (truncated) {
      text =
          '${text.substring(0, maxLength)}\n...(truncated, total ${page.cleanedText.length} chars)';
    }
    if (text.isEmpty) {
      throw ToolException('empty page content');
    }

    final payload = <String, dynamic>{
      'url': page.url,
      'title': page.title.isEmpty ? null : page.title,
      'text': text,
      'link_count': page.links.length,
    };

    if (linkText != null) {
      final match = _findLinkByText(page.links, linkText);
      if (match != null) {
        payload['link_url'] = match.url;
        payload['link_text_matched'] = match.text;
      } else {
        payload['link_error'] =
            'no link with text matching "$linkText" was found on this page';
      }
    }

    if (includeLinks) {
      const cap = 50;
      final slice = page.links.length > cap
          ? page.links.take(cap).toList()
          : page.links;
      payload['links'] = [
        for (final l in slice) {'text': l.text, 'url': l.url},
      ];
      if (page.links.length > cap) {
        payload['links_truncated'] = page.links.length - cap;
      }
    }

    return jsonEncode(payload);
  }

  static String _cleanWhitespace(String input) {
    return input
        .replaceAll(RegExp(r'\s+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
  }

  /// Walks the parsed document and returns a deduplicated list of
  /// anchor (`<a href=...>text</a>`) pairs, in document order.
  /// Empty / non-href anchors, javascript: / mailto: / tel:
  /// schemes, and anchors with no visible text are skipped.
  static List<_LinkEntry> _extractLinks(
    html_dom.Document doc, {
    required Uri baseUri,
  }) {
    final seen = <String>{};
    final out = <_LinkEntry>[];
    for (final a in doc.querySelectorAll('a')) {
      final href = a.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      Uri? resolved;
      try {
        resolved = baseUri.resolve(href);
      } catch (_) {
        continue;
      }
      if (!resolved.hasScheme) continue;
      final scheme = resolved.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') continue;
      // Normalize the visible text of the link: collapse internal
      // whitespace (anchors frequently break "About Us" into
      // "About\n  Us") and trim. Empty text is skipped — an anchor
      // with no visible text is not useful to the model.
      final rawText = a.text;
      final text = rawText.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final resolvedStr = _stripFragment(resolved);
      if (!seen.add(resolvedStr)) continue;
      out.add(_LinkEntry(text: text, url: resolvedStr));
    }
    return out;
  }

  /// Drops the URL fragment so the same page section under
  /// different anchors (`/docs#a` vs `/docs#b`) collapses into a
  /// single canonical URL for dedup / caching.
  ///
  /// Note: `Uri.replace(fragment: '')` is not enough — it sets the
  /// fragment to empty but the toString() of the resulting Uri
  /// still ends in `#` (the separator is kept even when the
  /// fragment is empty). We rebuild the string from the remaining
  /// components instead.
  static String _stripFragment(Uri u) {
    if (u.fragment.isEmpty) return u.toString();
    final out = StringBuffer();
    if (u.scheme.isNotEmpty) {
      out
        ..write(u.scheme)
        ..write(':');
    }
    if (u.hasAuthority) {
      // `u.authority` is just `host[:port]` — the `//` separator
      // is part of the URI syntax, not the authority component,
      // so we have to add it ourselves.
      out
        ..write('//')
        ..write(u.authority);
    }
    out.write(u.path);
    if (u.hasQuery) {
      out
        ..write('?')
        ..write(u.query);
    }
    return out.toString();
  }

  /// Finds the first link whose visible text matches [query].
  /// Strategy: case-insensitive, whitespace-normalized.
  ///   1. exact match (after normalization)
  ///   2. substring match (query is contained in link text)
  /// Returns `null` if no link matches.
  static _LinkEntry? _findLinkByText(List<_LinkEntry> links, String query) {
    final q = query.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final l in links) {
      if (l.text.toLowerCase() == q) return l;
    }
    for (final l in links) {
      if (l.text.toLowerCase().contains(q)) return l;
    }
    return null;
  }

  void dispose() {
    if (_ownsClient) _client.close();
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
    Future<String> runShell(String executable, List<String> args) async {
      try {
        final result = await Process.run(
          executable,
          args,
          runInShell: true,
        ).timeout(const Duration(seconds: 5));
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
      'user':
          Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          'unknown',
      'home':
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '',
      'shell':
          Platform.environment['SHELL'] ??
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

  // ---- Mobile / personal-data tools ----
  //
  // Each tool takes the raw argument map the model produced and
  // returns a JSON string the model can parse. Throws [ToolException]
  // on user input errors, permission denials, and platform
  // unavailability — the orchestrator turns those into failed tool
  // cards and surfaces the message to the model.

  static const _actionList = 'list';
  static const _actionGet = 'get';
  static const _actionCreate = 'create';
  static const _actionUpdate = 'update';
  static const _actionDelete = 'delete';
  static const _actionComplete = 'complete';

  /// Dispatches the unified `calendar` tool. The model picks the
  /// `action` and the rest of the parameters per the schema.
  Future<String> runCalendar(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? '';
    try {
      switch (action) {
        case _actionList:
          final fromMs = (args['from'] as num?)?.toInt();
          final toMs = (args['to'] as num?)?.toInt();
          if (fromMs == null || toMs == null) {
            throw ToolException('action=list requires "from" and "to" (ms)');
          }
          final max = (args['max'] as num?)?.toInt() ?? 50;
          final events = await calendar.listEvents(
            from: DateTime.fromMillisecondsSinceEpoch(fromMs),
            to: DateTime.fromMillisecondsSinceEpoch(toMs),
            max: max,
          );
          return jsonEncode({
            'action': 'list',
            'count': events.length,
            'events': events.map((e) => e.toJson()).toList(),
          });
        case _actionGet:
          final id = args['id'] as String? ?? '';
          if (id.isEmpty) throw ToolException('action=get requires "id"');
          final ev = await calendar.getEvent(id);
          if (ev == null) return jsonEncode({'action': 'get', 'found': false});
          return jsonEncode({
            'action': 'get',
            'found': true,
            'event': ev.toJson(),
          });
        case _actionCreate:
          final title = args['title'] as String? ?? '';
          final startMs = (args['start_ms'] as num?)?.toInt();
          if (title.isEmpty || startMs == null) {
            throw ToolException(
              'action=create requires "title" and "start_ms"',
            );
          }
          final ev = await calendar.createEvent(
            title: title,
            start: DateTime.fromMillisecondsSinceEpoch(startMs),
            end: (args['end_ms'] as num?)?.toInt() == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (args['end_ms'] as num).toInt(),
                  ),
            notes: args['notes'] as String?,
            location: args['location'] as String?,
            alarmMinutes: (args['alarm_minutes'] as num?)?.toInt(),
          );
          return jsonEncode({'action': 'create', 'event': ev.toJson()});
        case _actionUpdate:
          final id = args['id'] as String? ?? '';
          if (id.isEmpty) throw ToolException('action=update requires "id"');
          final existing = await calendar.getEvent(id);
          if (existing == null) {
            return jsonEncode({'action': 'update', 'found': false});
          }
          final patched = existing.copyWith(
            title: args['title'] as String?,
            start: (args['start_ms'] as num?)?.toInt() == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (args['start_ms'] as num).toInt(),
                  ),
            end: (args['end_ms'] as num?)?.toInt() == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (args['end_ms'] as num).toInt(),
                  ),
            notes: args['notes'] as String?,
            location: args['location'] as String?,
            alarmMinutes: (args['alarm_minutes'] as num?)?.toInt(),
          );
          final updated = await calendar.updateEvent(patched);
          if (updated == null) {
            return jsonEncode({'action': 'update', 'found': false});
          }
          return jsonEncode({'action': 'update', 'event': updated.toJson()});
        case _actionDelete:
          final id = args['id'] as String? ?? '';
          if (id.isEmpty) throw ToolException('action=delete requires "id"');
          final ok = await calendar.deleteEvent(id);
          return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
        default:
          throw ToolException(
            'unknown action: $action (expected list/get/create/update/delete)',
          );
      }
    } on ToolException {
      rethrow;
    } on UnsupportedError catch (e) {
      throw ToolException('${e.message} (calendar)');
    } on MissingPluginException {
      throw ToolException(
        'calendar tool is not available: native bridge not registered',
      );
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw ToolException(
          'calendar permission denied; please grant it in system settings',
        );
      }
      throw ToolException('calendar error: ${e.code}: ${e.message}');
    }
  }

  /// Dispatches the unified `reminders` tool. Android uses
  /// all-day calendar events under a user-picked "todo" calendar; iOS
  /// uses the Reminders framework directly.
  Future<String> runReminders(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? '';
    try {
      switch (action) {
        case _actionList:
          final includeCompleted = args['include_completed'] as bool? ?? false;
          final max = (args['max'] as num?)?.toInt() ?? 50;
          final items = await reminders.listReminders(
            includeCompleted: includeCompleted,
            max: max,
          );
          return jsonEncode({
            'action': 'list',
            'count': items.length,
            'reminders': items.map((r) => r.toJson()).toList(),
          });
        case _actionCreate:
          final title = args['title'] as String? ?? '';
          if (title.isEmpty) {
            throw ToolException('action=create requires "title"');
          }
          final dueMs = (args['due_ms'] as num?)?.toInt();
          final r = await reminders.createReminder(
            title: title,
            notes: args['notes'] as String?,
            due: dueMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(dueMs),
          );
          return jsonEncode({'action': 'create', 'reminder': r.toJson()});
        case _actionComplete:
          final id = args['id'] as String? ?? '';
          if (id.isEmpty) throw ToolException('action=complete requires "id"');
          final r = await reminders.completeReminder(id);
          if (r == null) {
            return jsonEncode({'action': 'complete', 'found': false});
          }
          return jsonEncode({'action': 'complete', 'reminder': r.toJson()});
        case _actionUpdate:
          final id = args['id'] as String? ?? '';
          if (id.isEmpty) throw ToolException('action=update requires "id"');
          final existing = await reminders.listReminders(
            includeCompleted: true,
            max: 200,
          );
          final target = existing.firstWhere(
            (r) => r.id == id,
            orElse: () => throw ToolException('reminder not found: $id'),
          );
          final patched = target.copyWith(
            title: args['title'] as String?,
            notes: args['notes'] as String?,
            due: (args['due_ms'] as num?)?.toInt() == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (args['due_ms'] as num).toInt(),
                  ),
          );
          final updated = await reminders.updateReminder(patched);
          if (updated == null) {
            return jsonEncode({'action': 'update', 'found': false});
          }
          return jsonEncode({'action': 'update', 'reminder': updated.toJson()});
        case _actionDelete:
          final id = args['id'] as String? ?? '';
          if (id.isEmpty) throw ToolException('action=delete requires "id"');
          final ok = await reminders.deleteReminder(id);
          return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
        default:
          throw ToolException(
            'unknown action: $action (expected list/create/complete/update/delete)',
          );
      }
    } on ToolException {
      rethrow;
    } on UnsupportedError catch (e) {
      throw ToolException('${e.message} (reminders)');
    } on MissingPluginException {
      throw ToolException(
        'reminders tool is not available: native bridge not registered',
      );
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw ToolException(
          'reminders permission denied; please grant it in system settings',
        );
      }
      if (e.code == 'NO_TODO_CALENDAR') {
        throw ToolException('请先在设置中选择一个本地日历作为"待办日历"');
      }
      throw ToolException('reminders error: ${e.code}: ${e.message}');
    }
  }

  /// Dispatches the unified `notes` tool. Backed by an in-app Hive
  /// box — works on every platform without OS permissions.
  Future<String> runNotes(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? '';
    switch (action) {
      case _actionList:
        final keyword = args['keyword'] as String?;
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final items = notes.list(keyword: keyword, max: max);
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'notes': items.map((n) => n.toJson()).toList(),
        });
      case _actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final n = notes.get(id);
        if (n == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({'action': 'get', 'found': true, 'note': n.toJson()});
      case _actionCreate:
        final title = args['title'] as String? ?? '';
        final content = args['content'] as String? ?? '';
        if (title.isEmpty) {
          throw ToolException('action=create requires "title"');
        }
        final n = await notes.create(title: title, content: content);
        return jsonEncode({'action': 'create', 'note': n.toJson()});
      case _actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final n = await notes.update(
          id: id,
          title: args['title'] as String?,
          content: args['content'] as String?,
        );
        if (n == null) return jsonEncode({'action': 'update', 'found': false});
        return jsonEncode({'action': 'update', 'note': n.toJson()});
      case _actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await notes.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      default:
        throw ToolException(
          'unknown action: $action (expected list/get/create/update/delete)',
        );
    }
  }

  /// Dispatches the unified `tasks` tool. Backed by an in-app Hive
  /// box. On Android this is the fallback when no system todo
  /// calendar is configured.
  Future<String> runTasks(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? '';
    switch (action) {
      case _actionList:
        final includeCompleted = args['include_completed'] as bool? ?? false;
        final max = (args['max'] as num?)?.toInt() ?? 50;
        final items = tasks.list(includeCompleted: includeCompleted, max: max);
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'tasks': items.map((t) => t.toJson()).toList(),
        });
      case _actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final t = tasks.get(id);
        if (t == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({'action': 'get', 'found': true, 'task': t.toJson()});
      case _actionCreate:
        final title = args['title'] as String? ?? '';
        if (title.isEmpty) {
          throw ToolException('action=create requires "title"');
        }
        final dueMs = (args['due_ms'] as num?)?.toInt();
        final t = await tasks.create(
          title: title,
          notes: args['notes'] as String?,
          due: dueMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(dueMs),
        );
        return jsonEncode({'action': 'create', 'task': t.toJson()});
      case _actionComplete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=complete requires "id"');
        final t = await tasks.complete(id);
        if (t == null) {
          return jsonEncode({'action': 'complete', 'found': false});
        }
        return jsonEncode({'action': 'complete', 'task': t.toJson()});
      case _actionUpdate:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final dueMs = (args['due_ms'] as num?)?.toInt();
        final t = await tasks.update(
          id: id,
          title: args['title'] as String?,
          notes: args['notes'] as String?,
          due: dueMs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(dueMs),
        );
        if (t == null) return jsonEncode({'action': 'update', 'found': false});
        return jsonEncode({'action': 'update', 'task': t.toJson()});
      case _actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await tasks.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      default:
        throw ToolException(
          'unknown action: $action (expected list/get/create/complete/update/delete)',
        );
    }
  }

  /// Dispatches the unified `memory` tool. Backed by an in-app Hive
  /// box (`memories`). AI writes memories with `source='ai'`, the
  /// user can also add / edit / delete memories from Settings.
  Future<String> runMemory(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? '';
    switch (action) {
      case _actionList:
        final max = (args['max'] as num?)?.toInt() ?? 20;
        final items = memories.list(max: max);
        return jsonEncode({
          'action': 'list',
          'count': items.length,
          'memories': items.map((m) => m.toJson()).toList(),
        });
      case 'search':
        // Preferred: keywords[] (multi-keyword fuzzy OR-match on
        // content + tags). Legacy: single `keyword` string for
        // backward compat with older prompts / models. Tag-only
        // searches (no keywords at all) are also allowed via the
        // `tags` array.
        final rawKeywords = args['keywords'];
        final List<String> keywords;
        if (rawKeywords is List) {
          keywords = rawKeywords.map((e) => e.toString()).toList();
        } else if (rawKeywords is String && rawKeywords.trim().isNotEmpty) {
          keywords = [rawKeywords];
        } else {
          final legacy = args['keyword'] as String? ?? '';
          if (legacy.trim().isNotEmpty) {
            keywords = [legacy];
          } else {
            keywords = const [];
          }
        }
        final tagsRaw = args['tags'];
        final List<String>? tags = tagsRaw is List
            ? tagsRaw.map((e) => e.toString()).toList()
            : null;
        if (keywords.isEmpty && (tags == null || tags.isEmpty)) {
          throw ToolException(
            'action=search requires non-empty "keywords" (array), "keyword" (string), or "tags" (array)',
          );
        }
        final max = (args['max'] as num?)?.toInt() ?? 20;
        final items = memories.list(keywords: keywords, tags: tags, max: max);
        return jsonEncode({
          'action': 'search',
          'keywords': keywords,
          'tags': ?tags,
          'count': items.length,
          'memories': items.map((m) => m.toJson()).toList(),
        });
      case _actionGet:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=get requires "id"');
        final m = memories.get(id);
        if (m == null) return jsonEncode({'action': 'get', 'found': false});
        return jsonEncode({
          'action': 'get',
          'found': true,
          'memory': m.toJson(),
        });
      case _actionCreate:
        final content = args['content'] as String? ?? '';
        if (content.trim().isEmpty) {
          throw ToolException('action=create requires "content"');
        }
        final tagsRaw = args['tags'];
        final tags = tagsRaw is List
            ? tagsRaw.map((e) => e.toString()).toList()
            : const <String>[];
        final m = await memories.add(
          content: content,
          source: 'ai',
          tags: tags,
        );
        return jsonEncode({'action': 'create', 'memory': m.toJson()});
      case 'update':
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=update requires "id"');
        final tagsRaw = args['tags'];
        final List<String>? tags = tagsRaw is List
            ? tagsRaw.map((e) => e.toString()).toList()
            : null;
        final m = await memories.update(
          id: id,
          content: args['content'] as String?,
          tags: tags,
        );
        if (m == null) return jsonEncode({'action': 'update', 'found': false});
        return jsonEncode({'action': 'update', 'memory': m.toJson()});
      case _actionDelete:
        final id = args['id'] as String? ?? '';
        if (id.isEmpty) throw ToolException('action=delete requires "id"');
        final ok = await memories.delete(id);
        return jsonEncode({'action': 'delete', 'id': id, 'ok': ok});
      case 'delete_batch':
        final ids = (args['ids'] as List?)?.cast<String>() ?? const [];
        if (ids.isEmpty) {
          throw ToolException('action=delete_batch requires non-empty "ids"');
        }
        await memories.deleteMany(ids);
        return jsonEncode({
          'action': 'delete_batch',
          'count': ids.length,
          'ok': true,
        });
      default:
        throw ToolException(
          'unknown action: $action (expected list/search/get/create/update/delete/delete_batch)',
        );
    }
  }

  /// Dispatches the unified `location` tool. On mobile the native
  /// bridge returns a GPS fix; on desktop / web it falls back to
  /// IP-based geolocation. The single action is `get`, which
  /// returns a JSON envelope of `{action, location}`.
  ///
  /// Permission flow: [LocationService.ensurePermission] is called
  /// first. If it returns [PlatformPermissionStatus.denied] that
  /// usually means the native side has just kicked off the system
  /// permission dialog and is waiting for the user; we then call
  /// [LocationService.getCurrentLocation] which itself will wait
  /// for the dialog to resolve. Permanent denial is final and
  /// surfaced immediately.
  Future<String> runLocation(Map<String, dynamic> args) async {
    final action = args['action'] as String? ?? 'get';
    switch (action) {
      case 'get':
        final timeoutMs = (args['timeout_ms'] as num?)?.toInt() ?? 10000;
        final timeout = Duration(milliseconds: timeoutMs);
        try {
          final status = await location.ensurePermission();
          if (status == PlatformPermissionStatus.notSupported) {
            throw ToolException(
              'location tool is not available: native bridge not registered',
            );
          }
          if (status == PlatformPermissionStatus.permanentlyDenied) {
            throw ToolException(
              'location permission permanently denied; open system settings to enable it',
            );
          }
          // status == granted: native side already has permission.
          // status == denied: native side just kicked off the OS
          // dialog (or the user declined without "don't ask again").
          // Either way, hand off to getCurrentLocation; the bridge
          // handles the "ask, wait, fetch" loop.
          final result = await location.getCurrentLocation(timeout: timeout);
          return jsonEncode({'action': 'get', 'location': result.toJson()});
        } on ToolException {
          rethrow;
        } on UnsupportedError catch (e) {
          throw ToolException('${e.message} (location)');
        } on MissingPluginException {
          throw ToolException(
            'location tool is not available: native bridge not registered',
          );
        } on PlatformException catch (e) {
          switch (e.code) {
            case 'PERMISSION_DENIED':
              throw ToolException(
                'location permission denied; please grant it in system settings',
              );
            case 'PERMANENTLY_DENIED':
              throw ToolException(
                'location permission permanently denied; open system settings to enable it',
              );
            case 'LOCATION_TIMEOUT':
              throw ToolException(
                'location request timed out; make sure GPS / network is available and try again',
              );
            case 'LOCATION_UNAVAILABLE':
              throw ToolException(
                'location unavailable; make sure location services are on and try again',
              );
            case 'NO_LOCATION':
              throw ToolException('no location returned by the platform');
            default:
              throw ToolException('location error: ${e.code}: ${e.message}');
          }
        } on TimeoutException {
          throw ToolException(
            'location request timed out; make sure GPS / network is available and try again',
          );
        } on SocketException catch (e) {
          throw ToolException('location error: ${e.message}');
        }
      default:
        throw ToolException('unknown action: $action (expected get)');
    }
  }
}

/// One fetched page, kept in the in-memory [_fetchCache] so that
/// subsequent [ToolService.fetchWeb] calls for the same URL (e.g.
/// with different `linkText` lookups) can skip the network round
/// trip and the HTML re-parse.
class _FetchedPage {
  _FetchedPage({
    required this.url,
    required this.title,
    required this.cleanedText,
    required this.links,
  });
  final String url;
  final String title;
  final String cleanedText;
  final List<_LinkEntry> links;
}

/// One anchor on a fetched page: its visible text and the
/// (fragment-stripped, absolute) URL it points at.
class _LinkEntry {
  _LinkEntry({required this.text, required this.url});
  final String text;
  final String url;
}
