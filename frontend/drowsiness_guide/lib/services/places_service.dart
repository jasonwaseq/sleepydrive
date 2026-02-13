import 'dart:convert';
import 'package:http/http.dart' as http;

class PlacesService {
  PlacesService({required this.apiKey});

  final String apiKey;

  Future<List<PlaceSummary>> fetchNearestGasStations({
    required double lat,
    required double lon,
    int limit = 5,
  }) async {
    if (apiKey.isEmpty || apiKey == 'YOUR_GOOGLE_PLACES_API_KEY') {
      throw Exception(
        'Missing Google Places API key. Set googlePlacesApiKey in lib/secrets.dart.',
      );
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/nearbysearch/json',
      {
        'location': '$lat,$lon',
        'rankby': 'distance',
        'type': 'gas_station',
        'key': apiKey,
      },
    );

    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Places HTTP ${res.statusCode}: ${res.body}');
    }

    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final status = (data['status'] ?? 'UNKNOWN') as String;
    if (status != 'OK' && status != 'ZERO_RESULTS') {
      final msg = (data['error_message'] ?? data['status'] ?? 'Unknown error').toString();
      throw Exception('Places error $status: $msg');
    }

    final results = (data['results'] as List? ?? const []);
    final places = <PlaceSummary>[];
    for (final item in results) {
      if (item is! Map<String, dynamic>) continue;

      final geometry = item['geometry'] as Map<String, dynamic>?;
      final location = geometry?['location'] as Map<String, dynamic>?;
      final pLat = (location?['lat'] as num?)?.toDouble();
      final pLng = (location?['lng'] as num?)?.toDouble();
      if (pLat == null || pLng == null) continue;

      final name = (item['name'] ?? 'Gas station').toString();
      final vicinity = (item['vicinity'] ?? item['formatted_address'] ?? '').toString();
      final placeId = (item['place_id'] ?? '').toString();

      places.add(
        PlaceSummary(
          name: name,
          vicinity: vicinity,
          placeId: placeId,
          lat: pLat,
          lon: pLng,
        ),
      );

      if (places.length >= limit) break;
    }

    return places;
  }
}

class PlaceSummary {
  final String name;
  final String vicinity;
  final String placeId;
  final double lat;
  final double lon;

  const PlaceSummary({
    required this.name,
    required this.vicinity,
    required this.placeId,
    required this.lat,
    required this.lon,
  });
}

