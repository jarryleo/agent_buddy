import 'dart:convert';

import 'package:agent_buddy/services/tool_service.dart';
import 'package:agent_buddy/services/tools/fetch_web_tool.dart';
import 'package:agent_buddy/services/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ToolService.fetchWeb', () {
    // Speed up retry backoff and clear the shared cache for tests.
    setUp(() {
      FetchWebTool.backoffBaseMs = 1;
      (ToolRegistry.byId('fetch_web') as FetchWebTool).clearCache();
    });

    test('returns a JSON envelope with title + text + link_count, '
        'and omits the link list by default', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://example.com/');
        return http.Response(
          '<html><head><title>Example</title></head>'
          '<body>'
          '<h1>Hello</h1>'
          '<p>Some intro text.</p>'
          '<a href="/about">About</a>'
          '<a href="/docs">Documentation</a>'
          '</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });
      final tools = ToolService(httpClient: client);
      final raw = await tools.fetchWeb('https://example.com/');
      final json = jsonDecode(raw) as Map<String, dynamic>;

      expect(json['url'], 'https://example.com/');
      expect(json['title'], 'Example');
      expect(json['text'], contains('Hello'));
      expect(json['text'], contains('Some intro text.'));
      expect(json['link_count'], 2);
      // The whole point of the new design: the link list is NOT in
      // the default response (saves tokens). It only appears when
      // the model explicitly asks for it via `include_links=true`.
      expect(json.containsKey('links'), isFalse);
      expect(json.containsKey('link_url'), isFalse);
    });

    test(
      'link_text matched: returns only link info (no page text/title)',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            '<html><head><title>Docs</title></head><body>'
            '<a href="/about">About Us</a>'
            '<a href="/docs/index.html">Documentation</a>'
            '<a href="https://other.example.com/x">External</a>'
            '</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb(
          'https://example.com/',
          linkText: 'Documentation',
        );
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json['link_text_matched'], 'Documentation');
        expect(json['link_url'], 'https://example.com/docs/index.html');
        // Should NOT return page content — model must call fetch_web again.
        expect(json.containsKey('title'), isFalse);
        expect(json.containsKey('text'), isFalse);
        expect(json.containsKey('link_count'), isFalse);
        expect(json['note'], contains('call fetch_web'));
        expect(json['note'], contains('/docs/index.html'));
      },
    );

    test('link_text is case-insensitive and whitespace-normalized', () async {
      final client = MockClient((req) async {
        return http.Response(
          '<html><body>'
          '<a href="/docs">  Documents  \n  page  </a>'
          '</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      final raw = await tools.fetchWeb(
        'https://example.com/',
        linkText: 'documents PAGE',
      );
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['link_url'], 'https://example.com/docs');
      expect(json.containsKey('text'), isFalse);
      expect(json['note'], contains('call fetch_web'));
    });

    test('link_text falls back from exact to substring match', () async {
      final client = MockClient((req) async {
        return http.Response(
          '<html><body>'
          '<a href="/contact">Contact Sales</a>'
          '<a href="/about">About Us</a>'
          '</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      // No link has the exact text "Contact" but "Contact Sales"
      // contains it — substring fallback should win.
      final raw = await tools.fetchWeb(
        'https://example.com/',
        linkText: 'Contact',
      );
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['link_url'], 'https://example.com/contact');
      expect(json.containsKey('text'), isFalse);
      expect(json['note'], contains('call fetch_web'));
    });

    test(
      'link_text returns link_error + full page content when no match',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            '<html><head><title>Test</title></head>'
            '<body><a href="/a">A</a><a href="/b">B</a></body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb(
          'https://example.com/',
          linkText: 'NonExistent',
        );
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json.containsKey('link_url'), isFalse);
        expect(json['link_error'], contains('no link with text matching'));
        expect(json['link_error'], contains('NonExistent'));
        // Falls back to full page content so the model can find the right text.
        expect(json['title'], 'Test');
        expect(json['text'], isNotEmpty);
        expect(json['link_count'], 2);
      },
    );

    test(
      'include_links=true returns the full anchor list, capped at 50',
      () async {
        // Build 60 anchors to verify the cap.
        final buf = StringBuffer('<html><body>');
        for (var i = 0; i < 60; i++) {
          buf.write('<a href="/p$i">Page $i</a>');
        }
        buf.write('</body></html>');
        final client = MockClient((req) async {
          return http.Response(
            buf.toString(),
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb(
          'https://example.com/',
          includeLinks: true,
        );
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json['link_count'], 60);
        final links = (json['links'] as List).cast<Map<String, dynamic>>();
        expect(links, hasLength(50));
        expect(json['links_truncated'], 10);
        expect(links.first['url'], 'https://example.com/p0');
        expect(links.first['text'], 'Page 0');
      },
    );

    test(
      'include_links=false (default) does NOT include the link list',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            '<html><body><a href="/a">A</a></body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb('https://example.com/');
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json.containsKey('links'), isFalse);
      },
    );

    test(
      'skips anchors with non-http(s) schemes (mailto, javascript, tel)',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            '<html><body>'
            '<a href="mailto:x@y.com">Mail</a>'
            '<a href="javascript:void(0)">JS</a>'
            '<a href="tel:123">Call</a>'
            '<a href="/ok">OK</a>'
            '</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb(
          'https://example.com/',
          includeLinks: true,
        );
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final links = (json['links'] as List).cast<Map<String, dynamic>>();
        expect(links, hasLength(1));
        expect(links.single['text'], 'OK');
      },
    );

    test('skips anchors with no visible text', () async {
      final client = MockClient((req) async {
        return http.Response(
          '<html><body>'
          '<a href="/a"><img src="x.png" alt=""></a>'
          '<a href="/b"><span>Hello</span></a>'
          '</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      final raw = await tools.fetchWeb(
        'https://example.com/',
        includeLinks: true,
      );
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final links = (json['links'] as List).cast<Map<String, dynamic>>();
      // Only the anchor with visible text "Hello" survives; the
      // one wrapping just an <img> with empty alt has no visible
      // text from the model's perspective and is dropped.
      expect(links, hasLength(1));
      expect(links.single['text'], 'Hello');
    });

    test('deduplicates links pointing to the same URL (with different '
        'fragments normalized away)', () async {
      final client = MockClient((req) async {
        return http.Response(
          '<html><body>'
          '<a href="/docs#a">A</a>'
          '<a href="/docs#b">B</a>'
          '<a href="/docs">C</a>'
          '</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      final raw = await tools.fetchWeb(
        'https://example.com/',
        includeLinks: true,
      );
      final json = jsonDecode(raw) as Map<String, dynamic>;
      // All three anchors resolve to /docs (fragments are stripped
      // for dedup) — only the first one survives.
      expect(json['link_count'], 1);
      final links = (json['links'] as List).cast<Map<String, dynamic>>();
      expect(links.single['text'], 'A');
    });

    test(
      'two calls with the same URL do not re-fetch (in-memory cache)',
      () async {
        var hits = 0;
        final client = MockClient((req) async {
          hits++;
          return http.Response(
            '<html><body>'
            '<a href="/a">A</a>'
            '<a href="/b">B</a>'
            '</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        // First call: cold cache → 1 network hit.
        await tools.fetchWeb('https://example.com/');
        // Second call with link_text: should hit the cache, not the
        // network. The model can re-query the same page cheaply.
        await tools.fetchWeb('https://example.com/', linkText: 'A');
        await tools.fetchWeb('https://example.com/', linkText: 'B');
        expect(hits, 1);
      },
    );

    test('rejects invalid URLs', () async {
      final client = MockClient((req) async => http.Response('', 200));
      final tools = ToolService(httpClient: client);
      expect(() => tools.fetchWeb('not a url'), throwsA(isA<ToolException>()));
      expect(
        () => tools.fetchWeb('/relative/path'),
        throwsA(isA<ToolException>()),
      );
    });

    test('non-2xx response is surfaced as HTTP <code>', () async {
      final client = MockClient((req) async {
        return http.Response('not found', 404);
      });
      final tools = ToolService(httpClient: client);
      expect(
        () => tools.fetchWeb('https://example.com/'),
        throwsA(
          isA<ToolException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 404'),
          ),
        ),
      );
    });

    test('empty page body is reported as empty', () async {
      final client = MockClient((req) async {
        return http.Response(
          '<html><body><script>var x = 1;</script></body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      // After stripping <script>, the page has no visible text.
      expect(
        () => tools.fetchWeb('https://example.com/'),
        throwsA(isA<ToolException>()),
      );
    });

    test(
      'JSON content-type is returned as pretty text (no link list)',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            '{"hello":"world","n":1}',
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb('https://api.example.com/data');
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json['url'], 'https://api.example.com/data');
        expect(json['text'], contains('"hello"'));
        expect(json['text'], contains('"world"'));
        expect(json['link_count'], 0);
        expect(json['title'], isNull);
      },
    );

    test(
      'retries on 429 (rate limited) and succeeds on third attempt',
      () async {
        var calls = 0;
        final client = MockClient((req) async {
          calls++;
          if (calls < 3) {
            return http.Response('', 429);
          }
          return http.Response(
            '<html><head><title>Retried</title></head><body>OK</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb('https://example.com/');
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json['title'], 'Retried');
        expect(json['text'], 'OK');
        expect(calls, 3);
      },
    );

    test('gives up after 3 retries on persistent 429', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('', 429);
      });
      final tools = ToolService(httpClient: client);
      await expectLater(
        tools.fetchWeb('https://example.com/'),
        throwsA(
          isA<ToolException>().having(
            (e) => e.message,
            'message',
            contains('rate limited'),
          ),
        ),
      );
      expect(calls, 3);
    });

    test('retries on 5xx and succeeds on second attempt', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response('', 502);
        }
        return http.Response(
          '<html><body>Recovered</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      final raw = await tools.fetchWeb('https://example.com/');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['text'], 'Recovered');
      expect(calls, 2);
    });

    test('gives up after 3 retries on persistent 5xx', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response('', 503);
      });
      final tools = ToolService(httpClient: client);
      await expectLater(
        tools.fetchWeb('https://example.com/'),
        throwsA(
          isA<ToolException>().having(
            (e) => e.message,
            'message',
            contains('503'),
          ),
        ),
      );
      expect(calls, 3);
    });

    test('sends realistic browser headers', () async {
      http.BaseRequest? capturedReq;
      final client = MockClient((req) async {
        capturedReq = req;
        return http.Response(
          '<html><body>OK</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });
      final tools = ToolService(httpClient: client);
      await tools.fetchWeb('https://example.com/');
      expect(capturedReq, isNotNull);
      // Must NOT use the old bot-like User-Agent.
      final ua = capturedReq!.headers['user-agent'];
      expect(ua, isNot(contains('AgentBuddy')));
      expect(ua, startsWith('Mozilla/5.0'));
      expect(capturedReq!.headers['accept-language'], contains('zh-CN'));
    });

    test(
      'truncates text to maxLength and reports the original length',
      () async {
        final client = MockClient((req) async {
          return http.Response(
            '<html><body>${'a' * 200}</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          );
        });
        final tools = ToolService(httpClient: client);
        final raw = await tools.fetchWeb('https://example.com/', maxLength: 50);
        final json = jsonDecode(raw) as Map<String, dynamic>;
        // 50 chars of 'a' + the truncation marker.
        expect(json['text'], startsWith('a' * 50));
        expect(json['text'], contains('truncated, total 200 chars'));
      },
    );
  });
}
