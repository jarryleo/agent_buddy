import 'dart:convert';

class GoogleSheetConfig {
  const GoogleSheetConfig({
    this.spreadsheetId = '',
    this.defaultTab = '',
    this.accessToken,
    this.refreshToken,
    this.tokenExpiresAtMs,
    this.authedEmail,
  });

  /// Spreadsheet ID extracted from the URL the user pastes
  /// (`https://docs.google.com/spreadsheets/d/<id>/edit`), or pasted
  /// directly. Empty string means "not configured".
  final String spreadsheetId;

  /// Default tab/sheet name the model operates on when an action
  /// omits an explicit `tab` argument. Cached client-side so the
  /// model doesn't need to specify it on every call. Refreshed by
  /// the settings UI's "刷新表格" button.
  final String defaultTab;

  /// OAuth 2.0 access token. Short-lived (1 hour). Used for every
  /// Sheets API call. Refreshed automatically via [refreshToken].
  final String? accessToken;

  /// OAuth 2.0 refresh token. Long-lived (until the user revokes
  /// access in their Google account or the OAuth grant expires
  /// after 6 months of inactivity). Used to mint a new
  /// [accessToken] without re-prompting the user.
  final String? refreshToken;

  /// Wall-clock time (epoch ms) when [accessToken] expires. Stored
  /// so we can refresh proactively (5 min before expiry) without
  /// getting a 401 first.
  final int? tokenExpiresAtMs;

  /// Email address of the authorized Google account. Purely
  /// informational — shown in the settings sheet so the user knows
  /// which account they authorized as. `null` until the first
  /// successful OAuth callback.
  final String? authedEmail;

  bool get hasSpreadsheet => spreadsheetId.isNotEmpty;
  bool get hasRefreshToken => refreshToken != null && refreshToken!.isNotEmpty;
  bool get hasAccessToken => accessToken != null && accessToken!.isNotEmpty;
  bool get isAuthorized => hasAccessToken || hasRefreshToken;

  /// True when the access token is missing or within 5 minutes of
  /// its declared expiry. The service uses this to decide whether
  /// to spend a refresh-token round-trip before the next request.
  bool get needsTokenRefresh {
    if (!hasAccessToken) return true;
    final exp = tokenExpiresAtMs;
    if (exp == null) return false;
    return DateTime.now().millisecondsSinceEpoch >= exp - 5 * 60 * 1000;
  }

  GoogleSheetConfig copyWith({
    String? spreadsheetId,
    String? defaultTab,
    String? accessToken,
    String? refreshToken,
    int? tokenExpiresAtMs,
    String? authedEmail,
    bool clearAccessToken = false,
    bool clearRefreshToken = false,
    bool clearExpiry = false,
    bool clearEmail = false,
  }) {
    return GoogleSheetConfig(
      spreadsheetId: spreadsheetId ?? this.spreadsheetId,
      defaultTab: defaultTab ?? this.defaultTab,
      accessToken: clearAccessToken ? null : (accessToken ?? this.accessToken),
      refreshToken: clearRefreshToken
          ? null
          : (refreshToken ?? this.refreshToken),
      tokenExpiresAtMs: clearExpiry
          ? null
          : (tokenExpiresAtMs ?? this.tokenExpiresAtMs),
      authedEmail: clearEmail ? null : (authedEmail ?? this.authedEmail),
    );
  }

  Map<String, dynamic> toJson() => {
    'spreadsheet_id': spreadsheetId,
    'default_tab': defaultTab,
    if (accessToken != null) 'access_token': accessToken,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (tokenExpiresAtMs != null) 'token_expires_at_ms': tokenExpiresAtMs,
    if (authedEmail != null) 'authed_email': authedEmail,
  };

  factory GoogleSheetConfig.fromJson(Map<String, dynamic> json) {
    return GoogleSheetConfig(
      spreadsheetId: json['spreadsheet_id'] as String? ?? '',
      defaultTab: json['default_tab'] as String? ?? '',
      accessToken: json['access_token'] as String?,
      refreshToken: json['refresh_token'] as String?,
      tokenExpiresAtMs: (json['token_expires_at_ms'] as num?)?.toInt(),
      authedEmail: json['authed_email'] as String?,
    );
  }

  String toRawJson() => jsonEncode(toJson());

  factory GoogleSheetConfig.fromRawJson(String raw) =>
      GoogleSheetConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  static const GoogleSheetConfig empty = GoogleSheetConfig();

  /// True when both the spreadsheet id and the OAuth tokens are
  /// in place. The settings UI uses this to gate the "enable"
  /// switch — without a valid config, the user has to first
  /// complete the one-time setup before the tool can be turned on.
  bool get isFullyConfigured => hasSpreadsheet && isAuthorized;
}
