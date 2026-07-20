import '../tool_service.dart';
import 'tool_base.dart';

class DownloadTool extends ToolBase {
  @override
  String get id => 'download';
  @override
  String get name => '下载文件';
  @override
  String get description =>
      '从网址下载文件到临时目录,用户得在界面上点"保存"才能存到磁盘。'
      '一次下载一个文件,多个文件就连续调用。手机和电脑可用,Web 不行。';
  @override
  String get shortDescription => '下载 URL 文件到临时目录(用户手动保存)';
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
              'description': '文件下载地址,带 http:// 或 https://',
            },
            'filename': {
              'type': 'string',
              'description': '可选。保存的文件名,不传就从 URL 自动推断。',
            },
          },
          'required': ['url'],
        },
      },
    };
  }

  @override
  String get compactSchemaForModel => '''
参数:
- url (string, 必填): 下载地址,带 http:// 或 https://
- filename (string, 可选): 保存的文件名;不传则从 URL path / Content-Disposition 推断

返回: 流式 DownloadItem 快照(pin 到气泡上),最终 completed/failed/cancelled。

约束 + 最佳实践:
- **一次下载一个文件**,多个文件就连续调 download。
- 模型永远拿不到本地路径(用户隐私),用户得在气泡上点"保存"才能落到磁盘;用户选完路径后临时文件会被删掉。
- Web 不可用(没有 temp dir)。
''';

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    throw ToolException(
      'download requires the chat provider for progress UI and is handled separately',
    );
  }
}
