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
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    throw ToolException(
      'download requires the chat provider for progress UI and is handled separately',
    );
  }
}
