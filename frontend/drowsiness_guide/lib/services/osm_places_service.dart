import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;

class OSMPlacesService {
  static const List<String> _endpoints = <String>[
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://overpass.openstreetmap.ru/api/interpreter',
  ];
  static const Duration _cacheTtl = Duration(minutes: 3);
  static const Duration _minRequestGap = Duration(seconds: 8);
  static final Map<String, _StopsCacheEntry> _cache = <String, _StopsCacheEntry>{};
  static final Map<String, DateTime> _lastAttemptAt = <String, DateTime>{};
  static final Map<String, Future<List<PlaceSummary>>> _inFlight =
      <String, Future<List<PlaceSummary>>>{};

  Future<List<PlaceSummary>> fetchNearestGasStations({
    required double lat,
    required double lon,
    int limit = 5,
    int radiusMeters = 5000,
  }) async {
    final key = _cacheKey(
      lat: lat,
      lon: lon,
      limit: limit,
      radiusMeters: radiusMeters,
    );
    final now = DateTime.now();
    final cached = _cache[key];

    if (cached != null && now.difference(cached.fetchedAt) <= _cacheTtl) {
      return cached.places;
    }

    final inFlight = _inFlight[key];
    if (inFlight != null) {
      return inFlight;
    }

    final lastAttempt = _lastAttemptAt[key];
    if (lastAttempt != null &&
        now.difference(lastAttempt) < _minRequestGap &&
        cached != null &&
        cached.places.isNotEmpty) {
      return cached.places;
    }
    _lastAttemptAt[key] = now;

    final task = _fetchFromMirrors(
      lat: lat,
      lon: lon,
      limit: limit,
      radiusMeters: radiusMeters,
      staleFallback: cached?.places,
    );
    _inFlight[key] = task;
    try {
      final places = await task;
      _cache[key] = _StopsCacheEntry(places: places, fetchedAt: DateTime.now());
      return places;
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 30 miles in meters (for rest stop radius).
  static const int _restStopRadiusMeters = 48280;

  /// Fetches rest stops (`highway=rest_area`) within 30 miles using Overpass mirrors.
  Future<List<PlaceSummary>> fetchRestStopsWithin30Miles({
    required double lat,
    required double lon,
  }) async {
    final query = '''
[out:json][timeout:15];
(
  node["highway"="rest_area"](around:$_restStopRadiusMeters,$lat,$lon);
  way["highway"="rest_area"](around:$_restStopRadiusMeters,$lat,$lon);
  relation["highway"="rest_area"](around:$_restStopRadiusMeters,$lat,$lon);
);
out center;
''';

    http.Response? okResponse;
    String? lastError;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final offset = startedAt % _endpoints.length;

    for (var i = 0; i < _endpoints.length; i++) {
      final endpoint = _endpoints[(offset + i) % _endpoints.length];
      try {
        final res = await http
            .post(
              Uri.parse(endpoint),
              headers: const {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Accept': 'application/json',
                'User-Agent': 'SleepyDrive/1.0 (Flutter)',
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 18));

        if (res.statusCode == 200) {
          okResponse = res;
          break;
        }

        lastError = 'Overpass HTTP ${res.statusCode}: ${res.body}';
        final retryable = res.statusCode == 429 || res.statusCode >= 500;
        if (retryable && i < _endpoints.length - 1) {
          await Future<void>.delayed(Duration(milliseconds: 350 * (i + 1)));
          continue;
        }
      } catch (e) {
        lastError = e.toString();
      }
    }

    if (okResponse == null) {
      throw Exception(
        'Failed to load rest stops from Overpass mirrors. ${lastError ?? ''}'.trim(),
      );
    }

    final data = jsonDecode(okResponse.body) as Map<String, dynamic>;
    final elements = (data['elements'] as List? ?? const []);

    final places = <PlaceSummary>[];

    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;

      final pLat = (el['lat'] as num?)?.toDouble() ??
          (el['center']?['lat'] as num?)?.toDouble();
      final pLon = (el['lon'] as num?)?.toDouble() ??
          (el['center']?['lon'] as num?)?.toDouble();
      if (pLat == null || pLon == null) continue;

      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final name = (tags['name'] ?? 'Rest area').toString();

      final street = tags['addr:street']?.toString();
      final housenumber = tags['addr:housenumber']?.toString();
      final city = tags['addr:city']?.toString();
      final state = tags['addr:state']?.toString();

      final parts = <String>[];
      if (street != null) {
        parts.add(housenumber == null ? street : '$housenumber $street');
      }
      if (city != null) parts.add(city);
      if (state != null) parts.add(state);

      final vicinity = parts.join(', ');

      places.add(
        PlaceSummary(
          name: name,
          vicinity: vicinity,
          lat: pLat,
          lon: pLon,
        ),
      );
    }

    places.sort((a, b) {
      final da = _haversineMeters(lat, lon, a.lat, a.lon);
      final db = _haversineMeters(lat, lon, b.lat, b.lon);
      return da.compareTo(db);
    });

    return places;
  }

  Future<List<PlaceSummary>> _fetchFromMirrors({
    required double lat,
    required double lon,
    required int limit,
    required int radiusMeters,
    List<PlaceSummary>? staleFallback,
  }) async {
    final query = '''
[out:json][timeout:10];
(
  node["amenity"="fuel"](around:$radiusMeters,$lat,$lon);
  way["amenity"="fuel"](around:$radiusMeters,$lat,$lon);
  relation["amenity"="fuel"](around:$radiusMeters,$lat,$lon);
);
out center $limit;
''';

    http.Response? okResponse;
    String? lastError;
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final offset = startedAt % _endpoints.length;

    for (var i = 0; i < _endpoints.length; i++) {
      final endpoint = _endpoints[(offset + i) % _endpoints.length];
      try {
        final res = await http
            .post(
              Uri.parse(endpoint),
              headers: const {
                'Content-Type': 'application/x-www-form-urlencoded',
                'Accept': 'application/json',
                // Some Overpass mirrors throttle generic clients aggressively.
                'User-Agent': 'SleepyDrive/1.0 (Flutter)',
              },
              body: {'data': query},
            )
            .timeout(const Duration(seconds: 12));

        if (res.statusCode == 200) {
          okResponse = res;
          break;
        }

        lastError = 'Overpass HTTP ${res.statusCode}: ${res.body}';
        final retryable = res.statusCode == 429 || res.statusCode >= 500;
        if (retryable && i < _endpoints.length - 1) {
          await Future<void>.delayed(Duration(milliseconds: 350 * (i + 1)));
          continue;
        }
      } catch (e) {
        lastError = e.toString();
      }
    }

    if (okResponse == null) {
      if (staleFallback != null && staleFallback.isNotEmpty) {
        return staleFallback;
      }
      throw Exception(
        'Failed to load stops from Overpass mirrors. ${lastError ?? ''}'.trim(),
      );
    }

    final data = jsonDecode(okResponse.body) as Map<String, dynamic>;
    final elements = (data['elements'] as List? ?? const []);

    final places = <PlaceSummary>[];

    for (final el in elements) {
      if (el is! Map<String, dynamic>) continue;

      final pLat = (el['lat'] as num?)?.toDouble() ??
          (el['center']?['lat'] as num?)?.toDouble();
      final pLon = (el['lon'] as num?)?.toDouble() ??
          (el['center']?['lon'] as num?)?.toDouble();
      if (pLat == null || pLon == null) continue;

      final tags = (el['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
      final name = (tags['name'] ?? 'Fuel / Gas station').toString();

      final street = tags['addr:street']?.toString();
      final housenumber = tags['addr:housenumber']?.toString();
      final city = tags['addr:city']?.toString();
      final state = tags['addr:state']?.toString();

      final parts = <String>[];
      if (street != null) {
        parts.add(housenumber == null ? street : '$housenumber $street');
      }
      if (city != null) parts.add(city);
      if (state != null) parts.add(state);

      final vicinity = parts.join(', ');

      places.add(
        PlaceSummary(
          name: name,
          vicinity: vicinity,
          lat: pLat,
          lon: pLon,
        ),
      );

      if (places.length >= limit) break;
    }

    places.sort((a, b) {
      final da = _haversineMeters(lat, lon, a.lat, a.lon);
      final db = _haversineMeters(lat, lon, b.lat, b.lon);
      return da.compareTo(db);
    });

    return places.take(limit).toList();
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = _deg2rad(lat2 - lat1);
    final dLon = _deg2rad(lon2 - lon1);
    final a = (sin(dLat / 2) * sin(dLat / 2)) +
        cos(_deg2rad(lat1)) * cos(_deg2rad(lat2)) *
            (sin(dLon / 2) * sin(dLon / 2));
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  double _deg2rad(double d) => d * (3.141592653589793 / 180.0);

  String _cacheKey({
    required double lat,
    required double lon,
    required int limit,
    required int radiusMeters,
  }) {
    // Coarser bucket (~1.1km) avoids cache misses from GPS jitter on web.
    final latBucket = (lat * 100).round();
    final lonBucket = (lon * 100).round();
    return '$latBucket:$lonBucket:$limit:$radiusMeters';
  }
}

class PlaceSummary {
  final String name;
  final String vicinity;
  final double lat;
  final double lon;

  const PlaceSummary({
    required this.name,
    required this.vicinity,
    required this.lat,
    required this.lon,
  });
}

class _StopsCacheEntry {
  final List<PlaceSummary> places;
  final DateTime fetchedAt;

  const _StopsCacheEntry({required this.places, required this.fetchedAt});
}