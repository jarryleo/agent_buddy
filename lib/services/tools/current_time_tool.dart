import 'dart:convert';

import '../tool_service.dart';
import 'tool_base.dart';

class CurrentTimeTool extends ToolBase {
  @override String get id => 'current_time';
  @override String get name => '当前时间';
  @override String get description => '获取当前日期和时间,返回本地时间、ISO 格式和 Unix 时间戳。';
  @override bool get isSupportedOnCurrentPlatform => true;

  @override Map<String, dynamic> buildSchema() {
    return {
      'type': 'function',
      'function': {'name': 'current_time', 'description': description,
        'parameters': {'type': 'object', 'properties': const <String, dynamic>{}, 'additionalProperties': false}},
    };
  }

  @override
  Future<String> execute(Map<String, dynamic> args, ToolService services) async {
    final now = DateTime.now();
    final offsetMinutes = now.timeZoneOffset.inMinutes;
    final localStr =
        '${_four(now.year)}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final isoLocal = now.toIso8601String();
    final isoUtc = now.toUtc().toIso8601String();
    final unix = now.millisecondsSinceEpoch ~/ 1000;
    final unixMillis = now.millisecondsSinceEpoch;
    final payload = {
      'local': localStr,
      'iso_local': isoLocal,
      'iso_utc': isoUtc,
      'unix': unix,
      'unix_millis': unixMillis,
      'timezone_offset_minutes': offsetMinutes,
      'timezone_name': now.timeZoneName,
    };
    return jsonEncode(payload);
  }

  String _four(int n) => n.toString().padLeft(4, '0');
  String _two(int n) => n.toString().padLeft(2, '0');
}
