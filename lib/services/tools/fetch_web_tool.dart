import 'tool_base.dart';

class FetchWebTool extends ToolBase {
  @override
  String get id => 'fetch_web';

  @override
  String get name => 'Fetch Web';

  @override
  String get description =>
      '抓取网页内容。看到有用链接就点进去继续看——把链接文字填到 link_text 参数,'
      '拿到新 URL 再抓一次。多级深入是正常操作,别只看首页。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'fetch_web',
        'description':
            '抓取网页返回 {url, title, text, link_count}。看到有用链接就把文字填到 link_text,'
            '工具返回 link_url,你再抓一次就能看到详情。一直深入直到找到答案。'
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
                  '填页面上看到的链接文字,工具会找到对应链接并返回 URL。'
                  '不区分大小写,先精确匹配再模糊匹配。拿到 URL 后继续 fetch_web 深入。',
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
