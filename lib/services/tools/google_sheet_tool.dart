import 'dart:convert';

import '../google_sheets_service.dart';
import '../tool_service.dart';
import 'tool_base.dart';

/// Built-in `google_sheet` tool. Exposes a CRUD surface against
/// the user's configured Google Sheet.
///
/// Scopes supported:
///   - list_tabs         → enumerate tabs in the spreadsheet
///   - read              → get values from a range
///   - update            → overwrite a range with new values
///   - append            → insert rows after a range
///   - clear             → blank out a range
///   - create_tab        → add a new tab/sheet
///   - delete_tab        → remove a tab/sheet
///   - format            → apply text / cell formatting
///
/// Platform: desktop only (Windows / macOS / Linux). The OAuth
/// loopback flow that backs this tool requires opening the
/// default browser and binding a localhost port — both unavailable
/// on mobile and web.
class GoogleSheetTool extends ToolBase {
  @override
  String get id => 'google_sheet';

  @override
  String get name => 'Google Sheet';

  @override
  String get description =>
      '读写用户在设置中配置的 Google Sheet。'
      '默认操作 default_tab 表;每个 action 可用 tab 参数覆盖。'
      'range 用 A1 表示法,支持单格、行、列、矩形。';

  @override
  bool get isEnabledByDefault => false;

  @override
  String get shortDescription => '读写用户的 Google Sheet(桌面端)';

  @override
  bool get isSupportedOnCurrentPlatform => isDesktop();

  @override
  String get compactSchemaForModel => '''
参数:
- action (string, 必填): list_tabs | read | update | append | clear | create_tab | delete_tab | format
- tab (string, 可选): 覆盖默认表,不带 ! 也行;range 无 ! 且省略 tab 时走默认表
- range (string, 看 action): A1 表示法 (A1 / A1:D10 / 5:5 / B:B / Sheet1!A1:D10)
- values (any[][], update/append 必填): 二维数组,按行填
- title (string, create_tab 必填): 新表名
- format 字段 (format 用): bold / italic / strikethrough / underline / font_size (int) / text_color (#RRGGBB) / background_color (#RRGGBB) / number_format_type (NUMBER|PERCENT|CURRENCY|DATE|TIME|DATE_TIME|SCIENTIFIC|TEXT) / number_format_pattern

返回:
- list_tabs: {action, spreadsheet_id, default_tab, count, tabs:[]}
- read: {action, range, rows, cols, values:2D}
- update/append: {action, updated_range, updated_rows, updated_columns, updated_cells}
- clear: {action, range, cleared:true}
- create_tab: {action, tab, sheet_id, index}
- delete_tab: {action, tab, sheet_id, deleted:true}
- format: {action, range, applied_fields:[]}

约束:
- spreadsheet_id 隐式从 settings 读,模型不传
- 401 → "Google 授权已过期,请重新测试连接"
- valueInputOption=USER_ENTERED(=A1+1 会算成公式)
''';

  @override
  Map<String, dynamic> buildSchema() {
    if (!isSupportedOnCurrentPlatform) return {};
    return {
      'type': 'function',
      'function': {
        'name': id,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {
              'type': 'string',
              'enum': const [
                'list_tabs',
                'read',
                'update',
                'append',
                'clear',
                'create_tab',
                'delete_tab',
                'format',
              ],
              'description':
                  '操作类型。list_tabs=列出所有表名;read/update/append/clear '
                  '用 range 操作格子;create_tab/delete_tab 增删整张表;'
                  'format 改文字/格子属性。',
            },
            'tab': {
              'type': 'string',
              'description': '可选。覆盖默认表名(带或不带 ! 都行)。若省略且 range 不含 !,用默认表。',
            },
            'range': {
              'type': 'string',
              'description':
                  'A1 表示法:`A1`(单格), `A1:D10`(矩形), `5:5`(整行), '
                  '`B:B`(整列), `Sheet1!A1:D10`(带表)。'
                  'read/update/append/clear/format 必填。',
            },
            'values': {
              'type': 'array',
              'description':
                  '二维数组,[[行1...], [行2...]]。update/append 必填。'
                  '单元格可填字符串/数字/布尔/null;以 `=` 开头的字符串会被当公式。',
              'items': {
                'type': 'array',
                'items': {
                  'anyOf': const [
                    {'type': 'string'},
                    {'type': 'number'},
                    {'type': 'boolean'},
                    {'type': 'null'},
                  ],
                },
              },
            },
            'title': {'type': 'string', 'description': 'create_tab 必填,新表名。'},
            'bold': {'type': 'boolean', 'description': 'format: 文字加粗。'},
            'italic': {'type': 'boolean', 'description': 'format: 文字斜体。'},
            'strikethrough': {
              'type': 'boolean',
              'description': 'format: 文字删除线。',
            },
            'underline': {'type': 'boolean', 'description': 'format: 文字下划线。'},
            'font_size': {
              'type': 'integer',
              'description': 'format: 字号(整数,7~72)。',
              'minimum': 7,
              'maximum': 72,
            },
            'text_color': {
              'type': 'string',
              'description': 'format: 文字颜色,十六进制 `#RRGGBB` 或 `#RRGGBBAA`。',
            },
            'background_color': {
              'type': 'string',
              'description': 'format: 格子背景色,十六进制 `#RRGGBB` 或 `#RRGGBBAA`。',
            },
            'number_format_type': {
              'type': 'string',
              'enum': const [
                'NUMBER',
                'PERCENT',
                'CURRENCY',
                'DATE',
                'TIME',
                'DATE_TIME',
                'SCIENTIFIC',
                'TEXT',
              ],
              'description': 'format: 数字格式类型。',
            },
            'number_format_pattern': {
              'type': 'string',
              'description': r'format: 自定义数字格式,例如 `"$#,##0.00"`、`"0.00%"`。',
            },
          },
          'required': const ['action'],
        },
      },
    };
  }

  @override
  Future<String> execute(
    Map<String, dynamic> args,
    ToolService services,
  ) async {
    final action = (args['action'] as String? ?? '').trim();
    if (action.isEmpty) {
      throw ToolException('google_sheet: "action" is required');
    }
    final svc = services.googleSheets;
    if (!svc.isReady) {
      throw ToolException(
        'google_sheet tool is not configured. '
        'Open Settings → Tools → Google Sheet, paste the spreadsheet URL '
        'or ID, click "测试连接" to authorize, and pick a default tab.',
      );
    }

    switch (action) {
      case 'list_tabs':
        final tabs = await svc.listTabs();
        return _envelope({
          'action': 'list_tabs',
          'spreadsheet_id': svc.config.spreadsheetId,
          'default_tab': svc.config.defaultTab,
          'count': tabs.length,
          'tabs': tabs,
        });

      case 'read':
        final range = _requireRange(action, args);
        final values = await svc.readRange(range, tab: args['tab'] as String?);
        return _envelope({
          'action': 'read',
          'range': range,
          'rows': values.length,
          'cols': values.isEmpty ? 0 : values.first.length,
          'values': values,
        });

      case 'update':
        final range = _requireRange(action, args);
        final values = _requireValues(action, args);
        final result = await svc.updateRange(
          range,
          values,
          tab: args['tab'] as String?,
        );
        return _envelope({'action': action, ...result.toJson()});

      case 'append':
        final range = _requireRange(action, args);
        final values = _requireValues(action, args);
        final result = await svc.appendRows(
          range,
          values,
          tab: args['tab'] as String?,
        );
        return _envelope({'action': action, ...result.toJson()});

      case 'clear':
        final range = _requireRange(action, args);
        final result = await svc.clearRange(range, tab: args['tab'] as String?);
        return _envelope({'action': action, ...result.toJson()});

      case 'create_tab':
        final title = (args['title'] as String? ?? '').trim();
        if (title.isEmpty) {
          throw ToolException(
            'google_sheet: action=create_tab requires "title"',
          );
        }
        final parsed = await svc.batchUpdate({
          'requests': [
            {
              'addSheet': {
                'properties': {'title': title},
              },
            },
          ],
        });
        return _envelope({
          'action': action,
          'title': title,
          'replies': parsed['replies'],
        });

      case 'delete_tab':
        final tabName = _resolveTabName(svc, args);
        final tabId = await _resolveTabId(svc, tabName);
        final parsed = await svc.batchUpdate({
          'requests': [
            {
              'deleteSheet': {'sheetId': tabId},
            },
          ],
        });
        return _envelope({
          'action': action,
          'tab': tabName,
          'tab_id': tabId,
          'replies': parsed['replies'],
        });

      case 'format':
        final range = _requireRange(action, args);
        final tabName = _resolveTabName(svc, args);
        final tabId = await _resolveTabId(svc, tabName);
        final gridRange = _a1ToGridRange(range, tabId);
        final request = _buildFormatRequest(args, gridRange);
        final parsed = await svc.batchUpdate({
          'requests': [request],
        });
        return _envelope({
          'action': action,
          'range': range,
          'tab': tabName,
          'replies': parsed['replies'],
        });

      default:
        throw ToolException(
          'google_sheet: unknown action "$action" '
          '(expected list_tabs/read/update/append/clear/'
          'create_tab/delete_tab/format)',
        );
    }
  }

  // ---- Helpers ----

  String _envelope(Map<String, dynamic> payload) => jsonEncode(payload);

  String _requireRange(String action, Map<String, dynamic> args) {
    final range = (args['range'] as String? ?? '').trim();
    if (range.isEmpty) {
      throw ToolException('google_sheet: action=$action requires "range"');
    }
    return range;
  }

  List<List<Object?>> _requireValues(String action, Map<String, dynamic> args) {
    final raw = args['values'];
    if (raw is! List || raw.isEmpty) {
      throw ToolException(
        'google_sheet: action=$action requires non-empty "values" '
        '(a 2D array, e.g. [["a","b"], ["c","d"]])',
      );
    }
    final out = <List<Object?>>[];
    for (final row in raw) {
      if (row is! List) {
        throw ToolException(
          'google_sheet: action=$action "values" must be a 2D array; '
          'got row of type ${row.runtimeType}',
        );
      }
      out.add([for (final cell in row) _normalizeCell(cell)]);
    }
    return out;
  }

  Object? _normalizeCell(Object? cell) {
    if (cell == null) return '';
    if (cell is String || cell is num || cell is bool) return cell;
    return cell.toString();
  }

  String _resolveTabName(GoogleSheetsService svc, Map<String, dynamic> args) {
    final raw = (args['tab'] as String? ?? '').trim();
    if (raw.isNotEmpty) return _stripTabQuotes(raw);
    final def = _stripTabQuotes(svc.config.defaultTab);
    if (def.isEmpty) {
      throw ToolException(
        'google_sheet: action needs "tab" (or set a default_tab in settings)',
      );
    }
    return def;
  }

  Future<int> _resolveTabId(GoogleSheetsService svc, String tabName) async {
    // Make sure the local tab cache is fresh.
    final tabs = await svc.listTabs();
    if (!tabs.contains(tabName)) {
      throw ToolException(
        'google_sheet: tab "$tabName" not found in spreadsheet; '
        'call action=list_tabs to see what\'s there',
      );
    }
    final token = await svc.ensureAccessToken();
    final props = await svc.fetchSheetProperties(token);
    for (final entry in props) {
      if (entry.title == tabName) return entry.sheetId;
    }
    throw ToolException(
      'google_sheet: could not resolve sheetId for "$tabName"',
    );
  }

  /// Convert an A1 range like `A1:C10` into the grid range format
  /// batchUpdate expects. The tab prefix (if any) is stripped —
  /// the caller passes the resolved `sheetId` separately.
  Map<String, dynamic> _a1ToGridRange(String a1, int sheetId) {
    final stripped = a1.contains('!') ? a1.split('!').last : a1;
    final parts = stripped.split(':');
    final start = parts.first;
    final end = parts.length > 1 ? parts.last : start;
    return {
      'sheetId': sheetId,
      'startRowIndex': _rowFromA1(start) - 1,
      'endRowIndex': _rowFromA1(end),
      'startColumnIndex': _colFromA1(start),
      'endColumnIndex': _colFromA1(end) + 1,
    };
  }

  static int _colFromA1(String ref) {
    var col = 0;
    for (final ch in ref.codeUnits) {
      final c = ch;
      if (c >= 0x41 && c <= 0x5A) {
        col = col * 26 + (c - 0x40);
      } else {
        break;
      }
    }
    return col - 1;
  }

  static int _rowFromA1(String ref) {
    final digits = StringBuffer();
    for (final ch in ref.codeUnits) {
      if (ch >= 0x30 && ch <= 0x39) {
        digits.writeCharCode(ch);
      } else if (digits.isNotEmpty) {
        break;
      }
    }
    return int.tryParse(digits.toString()) ?? 1;
  }

  Map<String, dynamic> _buildFormatRequest(
    Map<String, dynamic> args,
    Map<String, dynamic> gridRange,
  ) {
    final fields = <String>[];
    final textFormat = <String, dynamic>{};
    final bgColor = _parseHexColor(
      args['background_color'],
      'background_color',
    );
    final fgColor = _parseHexColor(args['text_color'], 'text_color');

    if (args['bold'] is bool) {
      textFormat['bold'] = args['bold'] as bool;
      fields.add('userEnteredFormat.textFormat.bold');
    }
    if (args['italic'] is bool) {
      textFormat['italic'] = args['italic'] as bool;
      fields.add('userEnteredFormat.textFormat.italic');
    }
    if (args['strikethrough'] is bool) {
      textFormat['strikethrough'] = args['strikethrough'] as bool;
      fields.add('userEnteredFormat.textFormat.strikethrough');
    }
    if (args['underline'] is bool) {
      textFormat['underline'] = args['underline'] as bool;
      fields.add('userEnteredFormat.textFormat.underline');
    }
    final fontSize = (args['font_size'] as num?)?.toInt();
    if (fontSize != null) {
      textFormat['fontSize'] = fontSize;
      fields.add('userEnteredFormat.textFormat.fontSize');
    }
    if (fgColor != null) {
      textFormat['foregroundColor'] = fgColor;
      fields.add('userEnteredFormat.textFormat.foregroundColor');
    }

    final numberFormatType = args['number_format_type'] as String?;
    final numberFormatPattern = args['number_format_pattern'] as String?;
    Map<String, dynamic>? numberFormat;
    if (numberFormatType != null) {
      numberFormat = {
        'type': numberFormatType,
        if (numberFormatPattern != null && numberFormatPattern.isNotEmpty)
          'pattern': numberFormatPattern,
      };
      fields.add('userEnteredFormat.numberFormat');
    }

    final userEnteredFormat = <String, dynamic>{};
    if (textFormat.isNotEmpty) userEnteredFormat['textFormat'] = textFormat;
    if (bgColor != null) userEnteredFormat['backgroundColor'] = bgColor;
    if (numberFormat != null) userEnteredFormat['numberFormat'] = numberFormat;
    if (bgColor != null) {
      userEnteredFormat['backgroundColor'] = bgColor;
      fields.add('userEnteredFormat.backgroundColor');
    }

    if (fields.isEmpty) {
      throw ToolException(
        'google_sheet: action=format needs at least one of '
        'bold/italic/strikethrough/underline/font_size/'
        'text_color/background_color/number_format_type',
      );
    }

    return {
      'repeatCell': {
        'range': gridRange,
        'cell': {'userEnteredFormat': userEnteredFormat},
        'fields': fields.join(','),
      },
    };
  }

  static Map<String, dynamic>? _parseHexColor(Object? raw, String name) {
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty) {
      throw ToolException(
        'google_sheet: format "$name" must be a hex string like "#RRGGBB"',
      );
    }
    var s = raw.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length != 6 && s.length != 8) {
      throw ToolException(
        'google_sheet: format "$name" must be "#RRGGBB" or "#RRGGBBAA"',
      );
    }
    final r = int.tryParse(s.substring(0, 2), radix: 16);
    final g = int.tryParse(s.substring(2, 4), radix: 16);
    final b = int.tryParse(s.substring(4, 6), radix: 16);
    if (r == null || g == null || b == null) {
      throw ToolException(
        'google_sheet: format "$name" has invalid hex digits',
      );
    }
    if (s.length == 8) {
      final a = int.tryParse(s.substring(6, 8), radix: 16);
      if (a == null) {
        throw ToolException(
          'google_sheet: format "$name" has invalid alpha hex',
        );
      }
      return {
        'red': r / 255.0,
        'green': g / 255.0,
        'blue': b / 255.0,
        'alpha': a / 255.0,
      };
    }
    return {'red': r / 255.0, 'green': g / 255.0, 'blue': b / 255.0};
  }

  static String _stripTabQuotes(String tab) {
    var t = tab.trim();
    if (t.startsWith("'") && t.endsWith("'") && t.length >= 2) {
      t = t.substring(1, t.length - 1).replaceAll("''", "'");
    }
    return t;
  }
}
