import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

/// `notification` tool — surfaces a title + body to the user via
/// the host platform's notification surface.
///
/// - **Mobile** (Android / iOS): a real OS-level local notification
///   via `NotificationService`. Effective only while the app is
///   running (the service posts immediately, no scheduling).
/// - **Desktop / web**: an in-app bottom-right toast overlay.
///
/// The model is expected to call this for two main flows:
///   1. Direct: the user says "remind me to do X" and the AI
///      immediately calls `notification.show`.
///   2. Indirect: the `timer` tool fired, ChatProvider sent a
///      synthetic user message back to the model, and the model
///      uses this tool to actually notify the user.
class NotificationTool extends ToolBase {
  @override
  String get id => 'notification';
  @override
  String get name => '通知';
  @override
  String get description => '向用户发送本地通知。手机用系统通知,电脑/Web 用应用内右下角弹窗。仅在程序运行时有效。';
  @override
  bool get isSupportedOnCurrentPlatform => true;

  @override
  Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {
        'name': 'notification',
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': const ['show'],
              'description': '固定 show',
            },
            'title': {'type': 'string', 'description': '通知标题,简短。'},
            'body': {'type': 'string', 'description': '通知正文,1-2 句话即可。'},
            'notification_id': {
              'type': 'integer',
              'description': '可选,自定义 id。传同一个 id 两次,新通知会替换旧的(用于更新未读通知)。',
            },
          },
          'required': const ['action', 'title', 'body'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final action = args['action'] as String? ?? '';
    if (action != 'show') {
      throw ToolException('unknown action: $action (expected show)');
    }
    final title = (args['title'] as String? ?? '').trim();
    final body = (args['body'] as String? ?? '').trim();
    if (title.isEmpty && body.isEmpty) {
      throw ToolException(
        'notification.show requires non-empty "title" or "body"',
      );
    }
    final id = (args['notification_id'] as num?)?.toInt();

    // Reuse the global NotificationService singleton — it's
    // already initialised at app start (see main.dart) and owns
    // the platform-specific send path.
    final sent = await services.notify(
      title: title.isEmpty ? '通知' : title,
      body: body,
      notificationId: id,
    );
    return jsonEncode({
      'action': 'show',
      'ok': sent,
      'title': title.isEmpty ? '通知' : title,
      'body': body,
    });
  }
}
