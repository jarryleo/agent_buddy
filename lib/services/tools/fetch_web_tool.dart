import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../tool_service.dart';
import 'tool_base.dart';

class FetchWebTool extends ToolBase {
  @override
  String get id => 'fetch_web';
  @override
  String get name => 'Fetch Web';
  @override
  String get description =>
      '抓取网页。填入 link_text 会直接返回匹配的链接 URL,不返回页面内容——'
      '你需要再调一次 fetch_web 来抓那个链接的页面。多级深入是正常操作,别只看首页。';
  @override
  String get shortDescription => '抓取网页正文(支持按链接文字深入)';
  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  String get compactSchemaForModel => '''
参数:
- url (string, 必填): 目标网址,带 http:// 或 https://
- link_text (string, 可选): 页面上看到的链接文字;返回匹配的 URL,**不返回页面内容**,需再调一次 fetch_web
- include_links (bool, 可选, 默认 false): 返回页面上全部链接(最多 50 条);仅当 link_text 不够用时用
- max_length (int, 可选, 默认 8000): 截断长度(字符)

返回:
- 默认: {url, title, text, link_count}
- 带 link_text 但命中: {url, link_url, link_text_matched, note}
- 带 link_text 但没命中: {url, text, link_count, link_error}
- include_links=true: 额外带 links: [{text,url}],上限 50

约束:
- 同一 URL + max_length 会本地缓存(16 条)
- 4xx/5xx/超时自动重试 3 次,指数退避
- 仅 http/https scheme,空响应抛 empty page content

最佳实践:
- link_text 只返回 URL,**必须再调一次 fetch_web** 抓那个链接的页面。
- 一路深入直到找到答案,别只看首页。
- 抓不到就换 UA(内置旋转)/ 换源 / 改 query,或告诉用户搜不到。
''';

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'fetch_web',
        'description':
            '抓取网页。不填 link_text 时返回 {url, title, text, link_count}。'
            '填 link_text 后只返回匹配的链接 URL + 提示——你需要再调一次 fetch_web 去抓那个链接的页面。'
            'include_links=true 是最后手段(最多 50 条),默认关闭省 token。',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': '目标网址,带 http:// 或 https://',
            },
            'link_text': {
              'type': 'string',
              'description':
                  '填页面上看到的链接文字,工具会找到链接并返回 URL(不返回页面内容)。'
                  '不区分大小写,先精确匹配再模糊匹配。拿到 URL 后还得再调一次 fetch_web 抓内容。',
            },
            'include_links': {
              'type': 'boolean',
              'description':
                  '设为 true 返回页面上所有链接(最多 50 条)。默认 false,优先用 link_text 深入。',
            },
          },
          'required': ['url'],
        },
      },
    };
  }

  // -- Per-URL page cache (bounded, per-tool-instance) --
  static const int _fetchCacheMaxEntries = 16;
  final Map<String, _FetchedPage> _fetchCache = <String, _FetchedPage>{};

  // -- User-Agent rotation --
  static const List<String> _userAgents = [
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0',
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
  ];
  static int _uaIndex = 0;

  static final Random _rng = Random.secure();

  /// Clear the in-memory page cache. Used by tests between runs.
  @visibleForTesting
  void clearCache() => _fetchCache.clear();

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final url = (args['url'] as String? ?? '').trim();
    if (url.isEmpty) {
      throw ToolException('url is required');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw ToolException('invalid URL: $url');
    }

    var linkText = args['link_text'] as String?;
    if (linkText != null && linkText.trim().isEmpty) {
      linkText = null;
    }
    final includeLinks = args['include_links'] as bool? ?? false;
    final maxLength = (args['max_length'] as num?)?.toInt() ?? 8000;

    return _fetchInternal(
      uri,
      linkText: linkText,
      includeLinks: includeLinks,
      maxLength: maxLength,
      client: services.httpClient,
    );
  }

  Future<String> _fetchInternal(
    Uri uri, {
    String? linkText,
    bool includeLinks = false,
    int maxLength = 8000,
    required http.Client client,
  }) async {
    final normalizedKey = uri.toString();
    final cacheKey = '$normalizedKey|$maxLength';

    _FetchedPage? page = _fetchCache[cacheKey];
    if (page == null) {
      await Future.delayed(Duration(milliseconds: 50 + _rng.nextInt(201)));

      http.Response resp;
      int attempts = 0;
      const maxAttempts = 3;
      while (true) {
        attempts++;
        try {
          resp = await client
              .get(uri, headers: _browserHeaders())
              .timeout(const Duration(seconds: 20));
        } on TimeoutException {
          if (attempts < maxAttempts) {
            await _backoff(attempts);
            continue;
          }
          throw ToolException('request timed out after $maxAttempts attempts');
        } catch (e) {
          if (attempts < maxAttempts && _isTransientError(e)) {
            await _backoff(attempts);
            continue;
          }
          throw ToolException(e.toString());
        }
        if (resp.statusCode == 429) {
          if (attempts < maxAttempts) {
            await _backoff(attempts);
            continue;
          }
          throw ToolException(
            'HTTP 429 (rate limited after $maxAttempts attempts)',
          );
        }
        if (resp.statusCode >= 500) {
          if (attempts < maxAttempts) {
            await _backoff(attempts);
            continue;
          }
          throw ToolException(
            'HTTP ${resp.statusCode} (after $maxAttempts attempts)',
          );
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw ToolException('HTTP ${resp.statusCode}');
        }
        break;
      }

      final contentType = resp.headers['content-type'] ?? '';
      if (contentType.contains('application/json')) {
        var text = const JsonEncoder.withIndent(
          '  ',
        ).convert(jsonDecode(utf8.decode(resp.bodyBytes)));
        if (text.length > maxLength) {
          text = '${text.substring(0, maxLength)}\n...(truncated)';
        }
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
      if (_fetchCache.length > _fetchCacheMaxEntries) {
        final oldestKey = _fetchCache.keys.first;
        _fetchCache.remove(oldestKey);
      }
    }

    if (linkText != null) {
      final match = _findLinkByText(page.links, linkText);
      if (match != null) {
        return jsonEncode({
          'url': page.url,
          'link_url': match.url,
          'link_text_matched': match.text,
          'note':
              'link found! call fetch_web with url="${match.url}" to get the linked page content',
        });
      }
    }

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
      payload['link_error'] =
          'no link with text matching "$linkText" was found on this page';
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

  Map<String, String> _browserHeaders() {
    final ua = _userAgents[_uaIndex % _userAgents.length];
    _uaIndex++;
    return {
      'User-Agent': ua,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Accept-Encoding': 'gzip, deflate, br',
      'Cache-Control': 'max-age=0',
      'Sec-Fetch-Dest': 'document',
      'Sec-Fetch-Mode': 'navigate',
      'Sec-Fetch-Site': 'none',
      'Sec-Fetch-User': '?1',
      'Upgrade-Insecure-Requests': '1',
      'DNT': '1',
      'Connection': 'keep-alive',
    };
  }

  @visibleForTesting
  static int backoffBaseMs = 1000;

  static Future<void> _backoff(int attempt) {
    final baseMs = (backoffBaseMs * pow(2, attempt - 1)).toInt();
    final jitter = _rng.nextInt(500);
    return Future.delayed(Duration(milliseconds: baseMs + jitter));
  }

  static bool _isTransientError(Object e) {
    if (e is SocketException) return true;
    if (e is HttpException) return true;
    if (e is TlsException) return true;
    if (e is HandshakeException) return true;
    return false;
  }

  static String _cleanWhitespace(String input) {
    return input
        .replaceAll(RegExp(r'\s+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
        .trim();
  }

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
      final rawText = a.text;
      final text = rawText.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      final resolvedStr = _stripFragment(resolved);
      if (!seen.add(resolvedStr)) continue;
      out.add(_LinkEntry(text: text, url: resolvedStr));
    }
    return out;
  }

  static String _stripFragment(Uri u) {
    if (u.fragment.isEmpty) return u.toString();
    final out = StringBuffer();
    if (u.scheme.isNotEmpty) {
      out
        ..write(u.scheme)
        ..write(':');
    }
    if (u.hasAuthority) {
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
}

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

class _LinkEntry {
  _LinkEntry({required this.text, required this.url});
  final String text;
  final String url;
}
