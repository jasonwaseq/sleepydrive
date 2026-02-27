import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

class OSMMapScreen extends StatefulWidget {
  final double? destLat;
  final double? destLng;

  const OSMMapScreen({super.key, this.destLat, this.destLng});

  @override
  State<OSMMapScreen> createState() => _OSMMapScreenState();
}

class _OSMMapScreenState extends State<OSMMapScreen> {
  final MapController _mapController = MapController();

  static const Color _brandBlue = Color(0xFF5E8AD6);
  static const Color _bgTop = Color(0xFFCED8E4);
  static const Color _bgBottom = Color(0xFF7E97B9);

  Position? _pos;
  LatLng? _dest;
  List<LatLng> _route = [];

  String _status = 'Loading location…';
  String _routeInfo = '';

  @override
  void initState() {
    super.initState();
    if (widget.destLat != null && widget.destLng != null) {
      _dest = LatLng(widget.destLat!, widget.destLng!);
    }
    _initLocation();
  }

  Future<void> _initLocation() async {
    try {
      setState(() => _status = 'Requesting location permission…');

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        setState(() => _status = 'Location permission denied forever.');
        return;
      }
      if (perm == LocationPermission.denied) {
        setState(() => _status = 'Location permission denied.');
        return;
      }

      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) {
        setState(() => _status = 'Location services are disabled.');
        return;
      }

      setState(() => _status = 'Getting current position…');
      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _pos = p;
        _status = 'Ready';
      });

      final me = LatLng(p.latitude, p.longitude);
      _mapController.move(me, 14);

      if (_dest != null) {
        await _buildRoute();
      }
    } catch (e) {
      setState(() => _status = 'Failed to get location: $e');
    }
  }

  Future<void> _buildRoute() async {
    if (_pos == null || _dest == null) return;

    final from = LatLng(_pos!.latitude, _pos!.longitude);
    final to = _dest!;

    setState(() {
      _status = 'Routing…';
      _route = [];
      _routeInfo = '';
    });

    final url = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
      '?overview=full&geometries=geojson',
    );

    try {
      final res = await http.get(url).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        setState(() => _status = 'Route error: HTTP ${res.statusCode}');
        return;
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final routes = data['routes'] as List<dynamic>?;

      if (routes == null || routes.isEmpty) {
        setState(() => _status = 'No route found.');
        return;
      }

      final r0 = routes[0] as Map<String, dynamic>;
      final distanceM = (r0['distance'] as num).toDouble();
      final durationS = (r0['duration'] as num).toDouble();

      final geometry = r0['geometry'] as Map<String, dynamic>;
      final coords = (geometry['coordinates'] as List<dynamic>)
          .cast<List<dynamic>>();

      final pts = coords
          .map((c) => LatLng(
                (c[1] as num).toDouble(),
                (c[0] as num).toDouble(),
              ))
          .toList();

      setState(() {
        _route = pts;
        _status = 'Ready';
        _routeInfo =
            'Distance: ${(distanceM / 1000).toStringAsFixed(2)} km • ETA: ${(durationS / 60).toStringAsFixed(0)} min';
      });

      _fitToPoints([from, to, ...pts]);
    } catch (e) {
      setState(() => _status = 'Routing failed: $e');
    }
  }

  void _fitToPoints(List<LatLng> points) {
    if (points.isEmpty) return;

    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;

    for (final p in points) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }

    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(64)),
    );
  }

  Future<void> _openGoogleNav() async {
    if (_pos == null || _dest == null) return;

    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&origin=${_pos!.latitude},${_pos!.longitude}'
      '&destination=${_dest!.latitude},${_dest!.longitude}'
      '&travelmode=driving',
    );

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Google Maps.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = _pos == null ? null : LatLng(_pos!.latitude, _pos!.longitude);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Map'),
        actions: [
          IconButton(
            tooltip: 'Re-center',
            onPressed: me == null ? null : () => _mapController.move(me, 15),
            icon: const Icon(Icons.my_location),
          ),
          IconButton(
            tooltip: 'Re-route',
            onPressed: (_pos != null && _dest != null) ? _buildRoute : null,
            icon: const Icon(Icons.alt_route),
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
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: me ?? const LatLng(36.9741, -122.0308),
                      initialZoom: 13,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate:
                            'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
                        subdomains: const ['a', 'b', 'c', 'd'],
                        retinaMode: true,
                        userAgentPackageName: 'drowsiness_guide',
                      ),

                      if (_route.isNotEmpty)
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: _route,
                              strokeWidth: 9,
                              color: Colors.black.withOpacity(0.22),
                              strokeCap: StrokeCap.round,
                              strokeJoin: StrokeJoin.round,
                            ),
                            Polyline(
                              points: _route,
                              strokeWidth: 6,
                              color: _brandBlue,
                              strokeCap: StrokeCap.round,
                              strokeJoin: StrokeJoin.round,
                            ),
                          ],
                        ),

                      MarkerLayer(
                        markers: [
                          if (me != null)
                            Marker(
                              point: me,
                              width: 22,
                              height: 22,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _brandBlue,
                                  border: Border.all(
                                      color: Colors.white, width: 2),
                                  boxShadow: const [
                                    BoxShadow(
                                      blurRadius: 8,
                                      color: Colors.black26,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (_dest != null)
                            Marker(
                              point: _dest!,
                              width: 24,
                              height: 24,
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFFD65E5E),
                                  border: Border.all(
                                      color: Colors.white, width: 2),
                                  boxShadow: const [
                                    BoxShadow(
                                      blurRadius: 8,
                                      color: Colors.black26,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),

                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: Colors.black.withOpacity(0.12)),
                        boxShadow: const [
                          BoxShadow(blurRadius: 12, color: Colors.black12),
                        ],
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _routeInfo.isNotEmpty ? _routeInfo : _status,
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (_dest != null)
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: _brandBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              onPressed: _openGoogleNav,
                              child: const Text('Navigate'),
                            ),
                        ],
                      ),
                    ),
                  ),

                  Positioned(
                    left: 12,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.88),
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: Colors.black.withOpacity(0.10)),
                      ),
                      child: const Text(
                        '© OpenStreetMap contributors • © CARTO',
                        style: TextStyle(fontSize: 11, color: Colors.black87),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}