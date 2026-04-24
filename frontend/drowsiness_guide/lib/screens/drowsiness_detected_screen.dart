import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:drowsiness_guide/screens/osm_map_screen.dart';
import 'package:drowsiness_guide/services/osm_places_service.dart';

class DrowsinessDetectedScreen extends StatefulWidget {
  const DrowsinessDetectedScreen({super.key});

  @override
  State<DrowsinessDetectedScreen> createState() =>
      _DrowsinessDetectedScreenState();
}

class _DrowsinessDetectedScreenState extends State<DrowsinessDetectedScreen> {
  static const Color _bgTop = Color(0xFFCED8E4);
  static const Color _bgBottom = Color(0xFF7E97B9);
  static const Color _brandBlue = Color(0xFF5E8AD6);
  static const Duration _loadTimeout = Duration(seconds: 10);
  static const String _locationServiceErrorMessage =
      'Location services error, check location permissions';

  bool _loading = false;
  String? _err;
  Position? _pos;
  List<_GasStationCardModel> _stations = const [];
  List<_RestStopCardModel> _restStops = const [];
  bool _restStopsLoading = false;

  @override
  void initState() {
    super.initState();
    _loadNearestGasStations();
  }

  Future<void> _loadNearestGasStations() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _err = null;
      _stations = const [];
      _restStops = const [];
      _restStopsLoading = true;
    });

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      ).timeout(_loadTimeout);

      final svc = OSMPlacesService();
      final gasFuture = svc
          .fetchNearestGasStations(
            lat: pos.latitude,
            lon: pos.longitude,
            limit: 5,
          )
          .timeout(_loadTimeout);
      final restFuture = svc
          .fetchRestStopsWithin30Miles(
            lat: pos.latitude,
            lon: pos.longitude,
          )
          .timeout(_loadTimeout);

      final places = await gasFuture;
      final restPlaces = await restFuture;

      final gasModels = places
          .map(
            (p) => _GasStationCardModel(
              name: p.name,
              vicinity: p.vicinity,
              lat: p.lat,
              lon: p.lon,
              distanceMeters: Geolocator.distanceBetween(
                pos.latitude,
                pos.longitude,
                p.lat,
                p.lon,
              ),
            ),
          )
          .toList(growable: false);
      final restModels = restPlaces
          .map(
            (p) => _RestStopCardModel(
              name: p.name,
              vicinity: p.vicinity,
              lat: p.lat,
              lon: p.lon,
              distanceMeters: Geolocator.distanceBetween(
                pos.latitude,
                pos.longitude,
                p.lat,
                p.lon,
              ),
            ),
          )
          .toList(growable: false);

      if (!mounted) return;
      setState(() {
        _pos = pos;
        _stations = gasModels;
        _restStops = restModels;
        _loading = false;
        _restStopsLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _err = _locationServiceErrorMessage;
        _loading = false;
        _restStopsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _err = _locationServiceErrorMessage;
        _loading = false;
        _restStopsLoading = false;
      });
    }
  }

  Future<void> _openDirections(_GasStationCardModel station) async {
    await _openDirectionsTo(station.lat, station.lon);
  }

  Future<void> _openDirectionsTo(double lat, double lon) async {
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '$lat,$lon',
      if (_pos != null) 'origin': '${_pos!.latitude},${_pos!.longitude}',
      'travelmode': 'driving',
    });

    final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps directions.')),
      );
    }
  }

  String _formatMiles(double meters) {
    final miles = meters / 1609.344;
    if (miles < 0.1) return '${(miles * 5280).round()} ft';
    return '${miles.toStringAsFixed(miles < 10 ? 1 : 0)} mi';
  }

  Widget _flatCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withOpacity(0.12)),
        boxShadow: const [
          BoxShadow(blurRadius: 12, color: Colors.black12),
        ],
      ),
      child: child,
    );
  }

  ButtonStyle _brandFilledButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: _brandBlue,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'DROWSINESS DETECTED',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 2.0),
        ),
        actions: [
          IconButton(
            onPressed: _loadNearestGasStations,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh nearby stops',
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bgTop, _bgBottom],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recommended Stops Nearby',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'If you feel drowsy, pull over somewhere safe.',
                  style: TextStyle(
                    color: Colors.black.withOpacity(0.65),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),

                if (_loading) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: const LinearProgressIndicator(minHeight: 6),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Finding nearby gas stations…',
                    style: TextStyle(color: Colors.black.withOpacity(0.65)),
                  ),
                ] else if (_err != null) ...[
                  _flatCard(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Could not load nearby stops.',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _err!,
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.65),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            style: _brandFilledButtonStyle(),
                            onPressed: _loadNearestGasStations,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else if (_stations.isEmpty) ...[
                  _flatCard(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        'No results found.',
                        style: TextStyle(color: Colors.black.withOpacity(0.7)),
                      ),
                    ),
                  ),
                ] else ...[
                  SizedBox(
                    height: 190,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _stations.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 12),
                      itemBuilder: (context, idx) {
                        final s = _stations[idx];

                        return SizedBox(
                          width: 295,
                          child: _flatCard(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (s.vicinity.isNotEmpty)
                                    Text(
                                      s.vicinity,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.black.withOpacity(0.65),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _formatMiles(s.distanceMeters),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black.withOpacity(0.8),
                                    ),
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: FilledButton(
                                          style: _brandFilledButtonStyle(),
                                          onPressed: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => OSMMapScreen(
                                                  destLat: s.lat,
                                                  destLng: s.lon,
                                                ),
                                              ),
                                            );
                                          },
                                          child: const Text('Preview Map'),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.black,
                                            side: BorderSide(
                                              color:
                                                  Colors.black.withOpacity(0.18),
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                          onPressed: () => _openDirections(s),
                                          child: const Text('Directions'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Preview Map shows the route in-app. Directions opens Google Maps.',
                    style: TextStyle(color: Colors.black.withOpacity(0.6)),
                  ),
                ],
                const SizedBox(height: 20),
                const Text(
                  'Rest stops within 30 miles',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 6),
                if (_restStopsLoading)
                  _flatCard(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Finding rest stops…',
                            style: TextStyle(color: Colors.black.withOpacity(0.65)),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_restStops.isEmpty)
                  _flatCard(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        'No rest stops within 30 miles',
                        style: TextStyle(color: Colors.black.withOpacity(0.7)),
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 190,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _restStops.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 12),
                      itemBuilder: (context, idx) {
                        final r = _restStops[idx];
                        return SizedBox(
                          width: 295,
                          child: _flatCard(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  if (r.vicinity.isNotEmpty)
                                    Text(
                                      r.vicinity,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.black.withOpacity(0.65),
                                      ),
                                    ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _formatMiles(r.distanceMeters),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      color: Colors.black.withOpacity(0.8),
                                    ),
                                  ),
                                  const Spacer(),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: FilledButton(
                                          style: _brandFilledButtonStyle(),
                                          onPressed: () {
                                            Navigator.push(
                                              context,
                                              MaterialPageRoute(
                                                builder: (_) => OSMMapScreen(
                                                  destLat: r.lat,
                                                  destLng: r.lon,
                                                ),
                                              ),
                                            );
                                          },
                                          child: const Text('Preview Map'),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.black,
                                            side: BorderSide(
                                              color:
                                                  Colors.black.withOpacity(0.18),
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                          onPressed: () =>
                                              _openDirectionsTo(r.lat, r.lon),
                                          child: const Text('Directions'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GasStationCardModel {
  final String name;
  final String vicinity;
  final double lat;
  final double lon;
  final double distanceMeters;

  const _GasStationCardModel({
    required this.name,
    required this.vicinity,
    required this.lat,
    required this.lon,
    required this.distanceMeters,
  });
}

class _RestStopCardModel {
  final String name;
  final String vicinity;
  final double lat;
  final double lon;
  final double distanceMeters;

  const _RestStopCardModel({
    required this.name,
    required this.vicinity,
    required this.lat,
    required this.lon,
    required this.distanceMeters,
  });
}