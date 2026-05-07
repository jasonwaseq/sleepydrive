import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drowsiness_guide/services/osm_places_service.dart';

Map<String, dynamic> _osmResponse(List<Map<String, dynamic>> elements) =>
    {'elements': elements};

Map<String, dynamic> _nodeEl({
  required double lat,
  required double lon,
  String name = 'Test Place',
}) =>
    {
      'lat': lat,
      'lon': lon,
      'tags': {'name': name},
    };

void main() {
  setUp(() => OSMPlacesService.clearCacheForTesting());

  // ---------------------------------------------------------------------------
  // fetchNearestGasStations
  // ---------------------------------------------------------------------------
  group('fetchNearestGasStations', () {
    test('returns parsed PlaceSummary list on 200', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode(_osmResponse([
              _nodeEl(lat: 10.001, lon: 20.001, name: 'Shell'),
              _nodeEl(lat: 10.002, lon: 20.002, name: 'BP'),
            ])),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final places = await svc.fetchNearestGasStations(lat: 10.0, lon: 20.0);
      expect(places.length, 2);
      expect(places.any((p) => p.name == 'Shell'), isTrue);
      expect(places.any((p) => p.name == 'BP'), isTrue);
    });

    test('returns empty list when no elements in response', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode(_osmResponse([])),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final places = await svc.fetchNearestGasStations(lat: 11.0, lon: 21.0);
      expect(places, isEmpty);
    });

    test('throws when all mirrors fail (non-retryable 404)', () async {
      final client = MockClient((req) async => http.Response('not found', 404));
      final svc = OSMPlacesService(httpClient: client);
      expect(
        () => svc.fetchNearestGasStations(lat: 12.0, lon: 22.0),
        throwsException,
      );
    });

    test('handles center-based coordinates for ways and relations', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'elements': [
                {
                  'center': {'lat': 10.001, 'lon': 20.001},
                  'tags': {'name': 'Way Station'},
                }
              ],
            }),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final places = await svc.fetchNearestGasStations(lat: 13.0, lon: 23.0);
      expect(places.any((p) => p.name == 'Way Station'), isTrue);
    });

    test('skips elements missing lat/lon', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'elements': [
                {'tags': {}},
                _nodeEl(lat: 10.001, lon: 20.001, name: 'Valid'),
              ],
            }),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final places = await svc.fetchNearestGasStations(lat: 14.0, lon: 24.0);
      expect(places.length, 1);
      expect(places.first.name, 'Valid');
    });

    test('honours limit parameter', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode(_osmResponse([
              _nodeEl(lat: 10.001, lon: 20.001, name: 'A'),
              _nodeEl(lat: 10.002, lon: 20.002, name: 'B'),
              _nodeEl(lat: 10.003, lon: 20.003, name: 'C'),
            ])),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final places = await svc.fetchNearestGasStations(
          lat: 15.0, lon: 25.0, limit: 2);
      expect(places.length, lessThanOrEqualTo(2));
    });
  });

  // ---------------------------------------------------------------------------
  // fetchRestStopsWithin30Miles
  // ---------------------------------------------------------------------------
  group('fetchRestStopsWithin30Miles', () {
    test('returns rest stop list on 200', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode(_osmResponse([
              _nodeEl(lat: 10.001, lon: 20.001, name: 'Rest Area 1'),
            ])),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final stops =
          await svc.fetchRestStopsWithin30Miles(lat: 10.0, lon: 20.0);
      expect(stops.length, 1);
      expect(stops.first.name, 'Rest Area 1');
    });

    test('returns empty list when no rest stops found', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode(_osmResponse([])),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final stops =
          await svc.fetchRestStopsWithin30Miles(lat: 16.0, lon: 26.0);
      expect(stops, isEmpty);
    });

    test('throws when all mirrors fail (non-retryable 404)', () async {
      final client = MockClient((req) async => http.Response('err', 404));
      final svc = OSMPlacesService(httpClient: client);
      expect(
        () => svc.fetchRestStopsWithin30Miles(lat: 17.0, lon: 27.0),
        throwsException,
      );
    });

    test('includes address in vicinity when tags present', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'elements': [
                {
                  'lat': 10.001,
                  'lon': 20.001,
                  'tags': {
                    'name': 'I-90 Rest Area',
                    'addr:street': 'Interstate 90',
                    'addr:city': 'Springfield',
                    'addr:state': 'MA',
                  },
                }
              ],
            }),
            200,
          ));
      final svc = OSMPlacesService(httpClient: client);
      final stops =
          await svc.fetchRestStopsWithin30Miles(lat: 18.0, lon: 28.0);
      expect(stops.first.vicinity, contains('Springfield'));
    });
  });
}
