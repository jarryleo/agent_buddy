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
  bool get isSupportedOnCurrentPlatform => true;

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
}
