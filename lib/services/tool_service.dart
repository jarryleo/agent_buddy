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
}
