import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

class ToolService {
  final http.Client _client = http.Client();

  Future<String> fetchWeb(String url, {int maxLength = 8000}) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      return 'Error: invalid URL: $url';
    }
    try {
      final resp = await _client
          .get(uri, headers: {
            'User-Agent':
                'Mozilla/5.0 (compatible; AgentBuddy/1.0; +https://agent.buddy)',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          })
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return 'Error: HTTP ${resp.statusCode}';
      }
      final contentType = resp.headers['content-type'] ?? '';
      if (contentType.contains('application/json')) {
        var text = const JsonEncoder.withIndent('  ').convert(jsonDecode(utf8.decode(resp.bodyBytes)));
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
      text = text.replaceAll(RegExp(r'\s+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
      text = text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
      if (text.length > maxLength) {
        text = '${text.substring(0, maxLength)}\n...(truncated, total ${text.length} chars)';
      }
      return text.isEmpty ? '(empty page content)' : text;
    } catch (e) {
      return 'Error: $e';
    }
  }

  void dispose() {
    _client.close();
  }
}
