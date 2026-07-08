import 'dart:convert';

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
}
