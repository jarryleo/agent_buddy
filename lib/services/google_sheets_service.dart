import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/google_sheet_config.dart';
import 'storage_service.dart';

/// Observable auth state of the Google Sheet tool. Drives the
/// settings sheet UI (which affordance is visible, which spinner
/// is shown, which error message is on screen).
enum GoogleSheetAuthState {
  /// No spreadsheet id and no tokens. Settings sheet should show
  /// the empty-state input.
  unconfigured,

  /// Spreadsheet id is set but the user hasn't authorized yet (or
  /// the tokens are gone). Settings sheet should prompt to retest
  /// the connection.
  unauthorized,

  /// A browser is open and we're waiting for the OAuth callback.
  /// Settings sheet should show a spinner + "complete the sign-in
  /// in your browser" message.
  authorizing,

  /// Tokens are present. Settings sheet should show the connected
  /// state with the email and the tab dropdown.
  authorized,

  /// The most recent operation failed. `stateError` carries the
  /// human-readable message. Settings sheet should show it inline
  /// with a retry affordance.
  error,
}

/// OAuth client credentials loaded from `assets/json/client_secret.json`.
/// Matches the shape of the bundled Google Desktop-app credential:
/// `{"installed": {"client_id": "...", "client_secret": "...",
///                  "auth_uri": "...", "token_uri": "...",
///                  "redirect_uris": ["http://127.0.0.1"]}}`.
class GoogleOAuthCredentials {
  const GoogleOAuthCredentials({
    required this.clientId,
    required this.clientSecret,
    required this.authUri,
    required this.tokenUri,
    required this.loopbackRedirectUri,
  });

  final String clientId;
  final String clientSecret;

  /// Google's authorization endpoint, pulled from
  /// `auth_uri` in `client_secret.json`. Falls back to the
  /// standard desktop-app endpoint when the asset omits it.
  final String authUri;

  final String tokenUri;

  /// The first `redirect_uri` declared in the client_secret.json
  /// file. The actual loopback URI used at runtime is derived from
  /// this base + an ephemeral port — we don't ship a port in the
  /// asset because `127.0.0.1` covers any port by default for
  /// "Desktop app" OAuth clients.
  final String loopbackRedirectUri;
}

/// Coordinates Google OAuth + the Google Sheets v4 REST API for the
/// built-in `google_sheet` tool.
///
/// Lifecycle:
///   1. Construct in `main.dart`.
///   2. Call [load] once during app startup to hydrate [config]
///      from SharedPreferences.
///   3. The settings sheet observes this `ChangeNotifier` to react
///      to auth-state transitions.
///   4. The `google_sheet` tool calls into [ensureAccessToken] +
///      Sheets API methods directly; it does not subscribe to
///      changes.
///
/// HTTP is delegated to an injected [http.Client] (the same one
/// `FetchWebTool` uses) so tests can swap in a `MockClient`.
class GoogleSheetsService extends ChangeNotifier {
  GoogleSheetsService({
    required StorageService storage,
    http.Client? httpClient,
    Future<GoogleOAuthCredentials> Function()? credentialsLoader,
    Future<bool> Function(Uri url)? urlLauncher,
    Duration httpTimeout = const Duration(seconds: 20),
    Duration authTimeout = const Duration(seconds: 90),
  }) : _storage = storage,
       _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _credentialsLoader = credentialsLoader ?? _defaultCredentialsLoader,
       _urlLauncher = urlLauncher ?? _defaultLaunchUrl,
       _httpTimeout = httpTimeout,
       _authTimeout = authTimeout;

  static const String _scopes =
      'https://www.googleapis.com/auth/spreadsheets '
      'https://www.googleapis.com/auth/userinfo.email';
  static const String _userInfoEndpoint =
      'https://www.googleapis.com/oauth2/v2/userinfo';
  static const String _sheetsBase = 'https://sheets.googleapis.com/v4';

  final StorageService _storage;
  final http.Client _client;
  final bool _ownsClient;
  final Future<GoogleOAuthCredentials> Function() _credentialsLoader;
  final Future<bool> Function(Uri url) _urlLauncher;
  final Duration _httpTimeout;
  final Duration _authTimeout;

  GoogleSheetConfig _config = GoogleSheetConfig.empty;
  GoogleSheetAuthState _state = GoogleSheetAuthState.unconfigured;
  String? _stateError;
  List<String> _availableTabs = const [];
  GoogleOAuthCredentials? _credentials;
  Future<String>? _refreshInFlight;

  // -- Public read-only state --

  GoogleSheetConfig get config => _config;
  GoogleSheetAuthState get state => _state;
  String? get stateError => _stateError;
  List<String> get availableTabs => List.unmodifiable(_availableTabs);

  /// Whether the tool is configured AND authorized enough to make
  /// Sheets API calls. The `google_sheet` tool checks this and
  /// throws a friendly error when false.
  bool get isReady =>
      _config.hasSpreadsheet &&
      _config.isAuthorized &&
      _state != GoogleSheetAuthState.error;

  /// Hydrate [config] from SharedPreferences. Called once at
  /// startup from `SettingsProvider.load`.
  Future<void> load() async {
    _config = _storage.loadGoogleSheetConfig();
    _recomputeState();
    notifyListeners();
  }

  /// Update the spreadsheet id + default tab from the settings UI
  /// and persist. The next call into the service will use these.
  Future<void> updateSelection({
    required String spreadsheetId,
    required String defaultTab,
  }) async {
    _config = _config.copyWith(
      spreadsheetId: spreadsheetId,
      defaultTab: defaultTab,
    );
    await _storage.saveGoogleSheetConfig(_config);
    _recomputeState();
    notifyListeners();
  }

  /// Clear any stored tokens and reset to `unauthorized`. Used by
  /// the settings UI when the user wants to re-authorize.
  Future<void> signOut() async {
    _config = _config.copyWith(
      clearAccessToken: true,
      clearRefreshToken: true,
      clearExpiry: true,
      clearEmail: true,
    );
    _availableTabs = const [];
    await _storage.saveGoogleSheetConfig(_config);
    _recomputeState();
    notifyListeners();
  }

  // -------- Auth flow --------

  /// Run the OAuth loopback flow:
  ///   1. Bind a localhost HTTP server on an ephemeral port.
  ///   2. Open the user's default browser to Google's auth URL.
  ///   3. Block until the callback lands (with [_authTimeout]).
  ///   4. Exchange the code for access + refresh tokens.
  ///   5. Save to SharedPreferences and flip state to `authorized`.
  ///
  /// Throws on every failure path with a human-readable message.
  /// On success, the authorized user's email is fetched once via
  /// the userinfo endpoint.
  Future<void> startAuthorization() async {
    if (!_config.hasSpreadsheet) {
      throw StateError(
        'startAuthorization called with empty spreadsheetId; '
        'the UI must call updateSelection first',
      );
    }
    _setState(GoogleSheetAuthState.authorizing);
    final creds = await _credentialsLoader();
    _credentials = creds;

    final stateToken = _randomToken(24);
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } on SocketException catch (e) {
      final message = e.message.isEmpty ? e.toString() : e.message;
      _fail('无法启动本地回调服务:$message');
      rethrow;
    }
    final port = server.port;
    final redirectUri = 'http://127.0.0.1:$port';

    final authUrl = Uri.parse(creds.authUri).replace(
      queryParameters: {
        'client_id': creds.clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': _scopes,
        'state': stateToken,
        'access_type': 'offline',
        'prompt': 'consent',
      },
    );

    final launched = await _urlLauncher(authUrl);
    if (!launched) {
      await server.close(force: true);
      _fail('无法打开浏览器,请手动复制授权链接');
      throw StateError('failed to launch browser for OAuth');
    }

    final code = await _captureCode(server, stateToken);
    await server.close(force: true);

    await _exchangeCodeForTokens(code: code, redirectUri: redirectUri);
    try {
      final email = await _fetchUserEmail();
      _config = _config.copyWith(authedEmail: email);
      await _storage.saveGoogleSheetConfig(_config);
    } catch (_) {
      // Non-fatal; the user is still authorized even if the
      // userinfo lookup fails.
    }
    _setState(GoogleSheetAuthState.authorized);
  }

  /// Test seam: complete the auth flow with a pre-captured code.
  /// Bypasses the localhost listener + browser launch. Used by
  /// tests that don't want to bind a real HttpServer.
  @visibleForTesting
  Future<void> completeAuthorizationWithCode({
    required String code,
    required String redirectUri,
  }) async {
    final creds = await _credentialsLoader();
    _credentials = creds;
    _setState(GoogleSheetAuthState.authorizing);
    await _exchangeCodeForTokens(code: code, redirectUri: redirectUri);
    try {
      final email = await _fetchUserEmail();
      _config = _config.copyWith(authedEmail: email);
      await _storage.saveGoogleSheetConfig(_config);
    } catch (_) {}
    _setState(GoogleSheetAuthState.authorized);
  }

  Future<String> _captureCode(HttpServer server, String stateToken) async {
    final completer = Completer<String>();
    final timer = Timer(_authTimeout, () {
      if (!completer.isCompleted) {
        server.close(force: true).catchError((_) {});
        completer.completeError(
          TimeoutException(
            'OAuth callback did not arrive within '
            '${_authTimeout.inSeconds} seconds',
          ),
        );
      }
    });
    server.listen((request) async {
      try {
        final params = request.uri.queryParameters;
        if (params['state'] != stateToken) {
          _writeHtml(request, '状态校验失败,请重试。', ok: false);
          if (!completer.isCompleted) {
            completer.completeError(StateError('OAuth state mismatch'));
          }
          return;
        }
        if (params['error'] != null) {
          _writeHtml(
            request,
            '授权被拒绝:${params['error_description'] ?? params['error']}',
            ok: false,
          );
          if (!completer.isCompleted) {
            completer.completeError(
              StateError(
                'OAuth error: ${params['error_description'] ?? params['error']}',
              ),
            );
          }
          return;
        }
        final code = params['code'];
        if (code == null || code.isEmpty) {
          _writeHtml(request, '授权码缺失,请重试。', ok: false);
          if (!completer.isCompleted) {
            completer.completeError(StateError('OAuth callback missing code'));
          }
          return;
        }
        _writeHtml(request, '授权成功!可以关闭此页面,返回 Agent Buddy。', ok: true);
        if (!completer.isCompleted) completer.complete(code);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  void _writeHtml(HttpRequest req, String message, {required bool ok}) {
    final color = ok ? '#1F6FEB' : '#D93025';
    final body =
        '<!doctype html><html><head><meta charset="utf-8">'
        '<title>Agent Buddy · Google 授权</title>'
        '<style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;'
        'background:#fafafa;color:#222;margin:0;padding:48px 16px;}'
        '.card{max-width:480px;margin:0 auto;background:#fff;border-radius:12px;'
        'padding:32px;box-shadow:0 2px 12px rgba(0,0,0,0.08);text-align:center;}'
        'h1{font-size:18px;color:$color;margin:0 0 12px;}'
        'p{font-size:14px;color:#555;line-height:1.6;margin:0;}'
        '</style></head><body><div class="card">'
        '<h1>Agent Buddy</h1><p>$message</p></div></body></html>';
    req.response.headers.contentType = ContentType.html;
    req.response.statusCode = 200;
    req.response.write(body);
    req.response.close();
  }

  Future<void> _exchangeCodeForTokens({
    required String code,
    required String redirectUri,
  }) async {
    final creds = _credentials!;
    final resp = await _client
        .post(
          Uri.parse(creds.tokenUri),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'code': code,
            'client_id': creds.clientId,
            'client_secret': creds.clientSecret,
            'redirect_uri': redirectUri,
            'grant_type': 'authorization_code',
          },
        )
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'token exchange');
    final tokens = _parseTokenResponse(body);
    _config = _config.copyWith(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken ?? _config.refreshToken,
      tokenExpiresAtMs: tokens.expiresAtMs,
    );
    await _storage.saveGoogleSheetConfig(_config);
  }

  /// Make sure we have a usable access token, refreshing via the
  /// refresh token if needed. Returns the access token. Throws
  /// with a setup hint when no tokens are present.
  Future<String> ensureAccessToken() async {
    if (!_config.isAuthorized) {
      throw StateError(
        'Google Sheet tool is not authorized. '
        'Open Settings → Tools → Google Sheet and click "测试连接".',
      );
    }
    if (!_config.needsTokenRefresh) {
      return _config.accessToken!;
    }
    // De-duplicate concurrent refresh attempts.
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final fut = _refreshAccessToken();
    _refreshInFlight = fut;
    try {
      return await fut;
    } finally {
      _refreshInFlight = null;
    }
  }

  Future<String> _refreshAccessToken() async {
    if (!_config.hasRefreshToken) {
      _fail('授权已过期,请重新测试连接');
      throw StateError('refresh token missing; user must re-authorize');
    }
    final creds = _credentials ?? await _credentialsLoader();
    _credentials = creds;
    final resp = await _client
        .post(
          Uri.parse(creds.tokenUri),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'client_id': creds.clientId,
            'client_secret': creds.clientSecret,
            'refresh_token': _config.refreshToken!,
            'grant_type': 'refresh_token',
          },
        )
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'token refresh');
    final tokens = _parseTokenResponse(body);
    _config = _config.copyWith(
      accessToken: tokens.accessToken,
      tokenExpiresAtMs: tokens.expiresAtMs,
    );
    await _storage.saveGoogleSheetConfig(_config);
    return tokens.accessToken;
  }

  Future<String?> _fetchUserEmail() async {
    final token = _config.accessToken;
    if (token == null) return null;
    final resp = await _client
        .get(
          Uri.parse(_userInfoEndpoint),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(_httpTimeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (body is! Map<String, dynamic>) return null;
    return body['email'] as String?;
  }

  // -------- Sheets API --------

  /// Fetch every tab/sheet name in the configured spreadsheet.
  /// Populates [availableTabs] and returns the same list.
  Future<List<String>> listTabs({String? spreadsheetId}) async {
    final id = spreadsheetId ?? _config.spreadsheetId;
    if (id.isEmpty) {
      throw StateError('spreadsheetId is empty; cannot list tabs');
    }
    final token = await ensureAccessToken();
    final uri = Uri.parse(
      '$_sheetsBase/spreadsheets/$id?fields=sheets/properties(title)',
    );
    final resp = await _client
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'listTabs');
    final sheets = (body['sheets'] as List?) ?? const [];
    final names = <String>[
      for (final s in sheets)
        ((s as Map)['properties'] as Map?)?['title'] as String? ?? '',
    ].where((s) => s.isNotEmpty).toList();
    _availableTabs = names;
    notifyListeners();
    return names;
  }

  /// Read a single range. [range] is A1 notation
  /// (`Sheet1!A1:C10`); if no tab prefix is given, the configured
  /// default tab is prepended.
  Future<List<List<Object?>>> readRange(
    String range, {
    String? spreadsheetId,
    String? tab,
  }) async {
    final a1 = _qualifyRange(range, tab);
    final id = spreadsheetId ?? _config.spreadsheetId;
    final token = await ensureAccessToken();
    final uri = Uri.parse(
      '$_sheetsBase/spreadsheets/$id/values/'
      '${Uri.encodeComponent(a1)}',
    );
    final resp = await _client
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'readRange');
    final values = body['values'];
    if (values is! List) return const [];
    return [
      for (final row in values)
        if (row is List) row.cast<Object?>() else <Object?>[],
    ];
  }

  /// Overwrite a range with [values]. Cells outside the target
  /// range are untouched. `valueInputOption=USER_ENTERED` lets the
  /// API parse formulas, dates, and numbers as if typed.
  Future<SheetMutationResult> updateRange(
    String range,
    List<List<Object?>> values, {
    String? spreadsheetId,
    String? tab,
  }) async {
    final a1 = _qualifyRange(range, tab);
    final id = spreadsheetId ?? _config.spreadsheetId;
    final token = await ensureAccessToken();
    final uri = Uri.parse(
      '$_sheetsBase/spreadsheets/$id/values/'
      '${Uri.encodeComponent(a1)}?valueInputOption=USER_ENTERED',
    );
    final resp = await _client
        .put(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'values': values}),
        )
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'updateRange');
    return _parseMutation(body, fallbackRange: a1);
  }

  /// Append rows to the end of a tab. Useful for batch inserts.
  Future<SheetMutationResult> appendRows(
    String range,
    List<List<Object?>> values, {
    String? spreadsheetId,
    String? tab,
  }) async {
    final a1 = _qualifyRange(range, tab);
    final id = spreadsheetId ?? _config.spreadsheetId;
    final token = await ensureAccessToken();
    final uri = Uri.parse(
      '$_sheetsBase/spreadsheets/$id/values/'
      '${Uri.encodeComponent(a1)}:append'
      '?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS',
    );
    final resp = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'values': values}),
        )
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'appendRows');
    return _parseMutation(body, fallbackRange: a1);
  }

  /// Clear every value in [range] (formatting preserved unless the
  /// caller uses a batchUpdate to remove it).
  Future<SheetMutationResult> clearRange(
    String range, {
    String? spreadsheetId,
    String? tab,
  }) async {
    final a1 = _qualifyRange(range, tab);
    final id = spreadsheetId ?? _config.spreadsheetId;
    final token = await ensureAccessToken();
    final uri = Uri.parse(
      '$_sheetsBase/spreadsheets/$id/values/'
      '${Uri.encodeComponent(a1)}:clear',
    );
    final resp = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        )
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'clearRange');
    return _parseMutation(body, fallbackRange: a1);
  }

  /// Send a raw `batchUpdate` request. Used for tab create / delete
  /// and cell-format changes, which aren't covered by the
  /// values-oriented endpoints.
  Future<Map<String, dynamic>> batchUpdate(
    Map<String, dynamic> body, {
    String? spreadsheetId,
  }) async {
    final id = spreadsheetId ?? _config.spreadsheetId;
    if (id.isEmpty) {
      throw StateError('spreadsheetId is empty; cannot batchUpdate');
    }
    final token = await ensureAccessToken();
    final uri = Uri.parse('$_sheetsBase/spreadsheets/$id:batchUpdate');
    final resp = await _client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(_httpTimeout);
    final parsed = _decodeOrThrow(resp, 'batchUpdate');
    return parsed;
  }

  /// Fetch every tab's `(sheetId, title)` pair for the configured
  /// spreadsheet. Used by the tool to resolve `tab → sheetId`
  /// before issuing `batchUpdate` calls. Always re-fetches (no
  /// cache) because the user may have added / removed tabs since
  /// the last call.
  Future<List<SheetProperty>> fetchSheetProperties(
    String bearer, {
    String? spreadsheetId,
  }) async {
    final id = spreadsheetId ?? _config.spreadsheetId;
    if (id.isEmpty) {
      throw StateError('spreadsheetId is empty; cannot fetch properties');
    }
    final uri = Uri.parse(
      '$_sheetsBase/spreadsheets/$id'
      '?fields=sheets/properties(sheetId,title)',
    );
    final resp = await _client
        .get(uri, headers: {'Authorization': 'Bearer $bearer'})
        .timeout(_httpTimeout);
    final body = _decodeOrThrow(resp, 'fetchSheetProperties');
    final sheets = (body['sheets'] as List?) ?? const [];
    return [
      for (final s in sheets)
        if (s is Map)
          SheetProperty(
            sheetId:
                ((s['properties'] as Map?)?['sheetId'] as num?)?.toInt() ?? 0,
            title: ((s['properties'] as Map?)?['title'] as String?) ?? '',
          ),
    ];
  }

  // -------- Helpers --------

  /// If [range] doesn't already contain a `!` tab prefix, prepend
  /// [tab] (or the configured default tab).
  String _qualifyRange(String range, String? tab) {
    if (range.contains('!')) return range;
    final resolvedTab = tab ?? _config.defaultTab;
    if (resolvedTab.isEmpty) {
      throw StateError(
        'range "$range" has no tab prefix and no default tab is configured',
      );
    }
    // Quote the tab name so spaces / punctuation survive the round-trip.
    final quoted = _needsQuoting(resolvedTab)
        ? "'${resolvedTab.replaceAll("'", "''")}'"
        : resolvedTab;
    return '$quoted!$range';
  }

  static bool _needsQuoting(String s) {
    return s.contains(' ') ||
        s.contains('-') ||
        s.contains('.') ||
        s.contains(',') ||
        s.contains('(') ||
        s.contains(')') ||
        s.contains("'");
  }

  void _setState(GoogleSheetAuthState newState) {
    _state = newState;
    _stateError = null;
    notifyListeners();
  }

  void _fail(String message) {
    _state = GoogleSheetAuthState.error;
    _stateError = message;
    notifyListeners();
  }

  void _recomputeState() {
    if (!_config.hasSpreadsheet) {
      _state = GoogleSheetAuthState.unconfigured;
      _stateError = null;
      return;
    }
    if (!_config.isAuthorized) {
      _state = GoogleSheetAuthState.unauthorized;
      _stateError = null;
      return;
    }
    _state = GoogleSheetAuthState.authorized;
    _stateError = null;
  }

  Map<String, dynamic> _decodeOrThrow(http.Response resp, String op) {
    if (resp.statusCode == 401) {
      _fail('Google 授权已过期,请重新测试连接');
      throw StateError('unauthorized');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final snippet = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (snippet.length > 400) {
        // Keep error messages sane for both the model and the user.
        throw StateError(
          'Google Sheets $op failed: HTTP ${resp.statusCode}: '
          '${snippet.substring(0, 400)}...',
        );
      }
      throw StateError(
        'Google Sheets $op failed: HTTP ${resp.statusCode}: $snippet',
      );
    }
    if (resp.bodyBytes.isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{'data': decoded};
  }

  SheetMutationResult _parseMutation(
    Map<String, dynamic> body, {
    required String fallbackRange,
  }) {
    final updatedRange = body['updatedRange'] as String? ?? fallbackRange;
    final updatedRows = (body['updatedRows'] as num?)?.toInt() ?? 0;
    final updatedColumns = (body['updatedColumns'] as num?)?.toInt() ?? 0;
    final updatedCells = (body['updatedCells'] as num?)?.toInt() ?? 0;
    return SheetMutationResult(
      updatedRange: updatedRange,
      updatedRows: updatedRows,
      updatedColumns: updatedColumns,
      updatedCells: updatedCells,
    );
  }

  static String _randomToken(int byteLen) {
    final rng = Random.secure();
    final bytes = List<int>.generate(byteLen, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static const String _defaultAuthUri =
      'https://accounts.google.com/o/oauth2/auth';

  static Future<GoogleOAuthCredentials> _defaultCredentialsLoader() async {
    final raw = await rootBundle.loadString('assets/json/client_secret.json');
    final outer = jsonDecode(raw) as Map<String, dynamic>;
    final installed = outer['installed'] as Map<String, dynamic>?;
    if (installed == null) {
      throw StateError(
        'assets/json/client_secret.json is missing the "installed" key',
      );
    }
    final clientId = installed['client_id'] as String?;
    final clientSecret = installed['client_secret'] as String?;
    final tokenUri = installed['token_uri'] as String?;
    final redirectUris = installed['redirect_uris'] as List?;
    final loopbackRedirectUri = redirectUris == null || redirectUris.isEmpty
        ? 'http://127.0.0.1'
        : redirectUris.first as String;
    if (clientId == null || clientSecret == null || tokenUri == null) {
      throw StateError(
        'assets/json/client_secret.json is missing one of '
        'client_id / client_secret / token_uri',
      );
    }
    // Google's Desktop-app credentials always use the standard
    // authorization-code endpoint, even if the file omits auth_uri.
    return GoogleOAuthCredentials(
      clientId: clientId,
      clientSecret: clientSecret,
      authUri: (installed['auth_uri'] as String?) ?? _defaultAuthUri,
      tokenUri: tokenUri,
      loopbackRedirectUri: loopbackRedirectUri,
    );
  }

  static Future<bool> _defaultLaunchUrl(Uri url) async {
    return launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @visibleForTesting
  void debugSetStateForTest(GoogleSheetAuthState newState) {
    _state = newState;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// What the Sheets `update` / `append` / `clear` endpoints return
/// in their JSON envelope. Exposed so the tool can pass it back to
/// the model in a compact form.
class SheetMutationResult {
  const SheetMutationResult({
    required this.updatedRange,
    required this.updatedRows,
    required this.updatedColumns,
    required this.updatedCells,
  });

  /// A1 range the API actually touched. May be larger than the
  /// caller-supplied range when appending.
  final String updatedRange;

  /// Number of rows touched.
  final int updatedRows;

  /// Number of columns touched.
  final int updatedColumns;

  /// Total cells touched.
  final int updatedCells;

  Map<String, dynamic> toJson() => {
    'updated_range': updatedRange,
    'updated_rows': updatedRows,
    'updated_columns': updatedColumns,
    'updated_cells': updatedCells,
  };
}

/// Minimal projection of a spreadsheet tab's properties. Just
/// enough for the tool to resolve `tab → sheetId` before issuing
/// batchUpdate calls.
class SheetProperty {
  const SheetProperty({required this.sheetId, required this.title});
  final int sheetId;
  final String title;
}

class _TokenResponse {
  const _TokenResponse({
    required this.accessToken,
    required this.expiresAtMs,
    this.refreshToken,
  });

  factory _TokenResponse.fromJson(Map<String, dynamic> json) {
    final access = json['access_token'] as String?;
    if (access == null || access.isEmpty) {
      throw StateError('token response missing access_token');
    }
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
    return _TokenResponse(
      accessToken: access,
      refreshToken: json['refresh_token'] as String?,
      expiresAtMs: DateTime.now()
          .add(Duration(seconds: expiresIn))
          .millisecondsSinceEpoch,
    );
  }

  final String accessToken;
  final String? refreshToken;
  final int expiresAtMs;
}

_TokenResponse _parseTokenResponse(Map<String, dynamic> json) =>
    _TokenResponse.fromJson(json);
