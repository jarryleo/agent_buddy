import 'tool_base.dart';

class DownloadTool extends ToolBase {
  @override
  String get id => 'download';

  @override
  String get name => '下载文件';

  @override
  String get description =>
      '从指定 URL 下载文件到 APP 临时目录'
      '(用户须在气泡上点"保存"才能把文件真正落到磁盘上,'
      '文件类型 / 格式由 URL 决定)。'
      '返回 JSON 信封包含 action / id / url / filename / size_bytes。'
      '每次调用下载一个文件,需要下载多个文件就连续调用多次。'
      '移动端 / 桌面端可用,Web 不可用(没有文件系统)。';

  @override
  bool get isSupportedOnCurrentPlatform => notWeb();

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': 'download',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': '要下载的文件的 URL,必须包含协议 (http:// 或 https://)。',
            },
            'filename': {
              'type': 'string',
              'description':
                  '可选。保存时使用的文件名。若不传,工具会从 URL 路径或 Content-Disposition 头推断。',
            },
          },
          'required': ['url'],
        },
      },
    };
  }
}
