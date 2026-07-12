import 'tool_base.dart';

class FetchWebTool extends ToolBase {
  @override
  String get id => 'fetch_web';

  @override
  String get name => 'Fetch Web';

  @override
  String get description =>
      '获取指定网址的内容,返回网页的纯文本。要进入下一级页面,'
      '用 link_text 参数把页面上看到的链接文字传进去即可取到对应 URL,'
      '不必把整个页面的链接列表都拉回来。';

  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'fetch_web',
        'description':
            '获取指定 URL 的内容,返回 JSON 信封(url/title/text/link_count)。'
            '要跟随页面上某个链接进入下一级,把看到的链接文字通过 link_text 传进来,'
            '工具会返回 link_url,再对那个 URL 调一次 fetch_web 即可实现多级跳转。'
            'include_links=true 仅作为最后手段(最多返回 50 条),默认关闭以节约 token。',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': '要抓取的 URL,必须包含协议 (http:// 或 https://)。',
            },
            'link_text': {
              'type': 'string',
              'description':
                  '可选。填页面上看到的链接文字,工具会在页面里查找对应锚点并返回其 URL (link_url)。'
                  '大小写不敏感,先精确匹配再退回到子串匹配。',
            },
            'include_links': {
              'type': 'boolean',
              'description':
                  '可选,默认 false。设为 true 则返回页面上所有链接的 {text, url} 数组(最多 50 条)。'
                  '默认关闭以节约 token,优先用 link_text 导航。',
            },
          },
          'required': ['url'],
        },
      },
    };
  }
}
