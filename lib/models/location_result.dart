class LocationResult {
  final double latitude;
  final double longitude;
  final double? accuracyMeters;
  final String? city;
  final String? region;
  final String? country;
  final String? countryCode;
  final String? timezone;
  final String? isp;
  final String source;
  final DateTime fetchedAt;

  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.source,
    required this.fetchedAt,
    this.accuracyMeters,
    this.city,
    this.region,
    this.country,
    this.countryCode,
    this.timezone,
    this.isp,
  });

  factory LocationResult.fromGps({
    required double latitude,
    required double longitude,
    double? accuracyMeters,
    String? city,
    String? region,
    String? country,
    String? countryCode,
    String? timezone,
    DateTime? fetchedAt,
  }) {
    return LocationResult(
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracyMeters,
      city: city,
      region: region,
      country: country,
      countryCode: countryCode,
      timezone: timezone,
      source: 'gps',
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
  }

  factory LocationResult.fromIp({
    required double latitude,
    required double longitude,
    String? city,
    String? region,
    String? country,
    String? countryCode,
    String? timezone,
    String? isp,
    DateTime? fetchedAt,
  }) {
    return LocationResult(
      latitude: latitude,
      longitude: longitude,
      city: city,
      region: region,
      country: country,
      countryCode: countryCode,
      timezone: timezone,
      isp: isp,
      source: 'ip',
      fetchedAt: fetchedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    if (accuracyMeters != null) 'accuracyMeters': accuracyMeters,
    if (city != null) 'city': city,
    if (region != null) 'region': region,
    if (country != null) 'country': country,
    if (countryCode != null) 'countryCode': countryCode,
    if (timezone != null) 'timezone': timezone,
    if (isp != null) 'isp': isp,
    'source': source,
    'fetchedAtMs': fetchedAt.millisecondsSinceEpoch,
  };

  factory LocationResult.fromJson(Map<String, dynamic> json) {
    return LocationResult(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
      city: json['city'] as String?,
      region: json['region'] as String?,
      country: json['country'] as String?,
      countryCode: json['countryCode'] as String?,
      timezone: json['timezone'] as String?,
      isp: json['isp'] as String?,
      source: json['source'] as String? ?? 'unknown',
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['fetchedAtMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}
