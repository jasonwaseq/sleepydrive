import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/weather_service.dart';
import '../secrets.dart';

Color _white(double opacity) => Colors.white.withAlpha((opacity * 255).round());

class LiveMonitorScreen extends StatefulWidget {
  const LiveMonitorScreen({super.key});

  @override
  State<LiveMonitorScreen> createState() => _LiveMonitorScreenState();
}

class _LiveMonitorScreenState extends State<LiveMonitorScreen> {
  String? _latText;
  String? _lonText;
  String? _locErr;
  String? _weatherCondition;
  String? _tempText;
  String? _weatherErr;

  bool _weatherLoading = false;

  @override
  void initState() {
    super.initState();
    _loadLocationOnce();
  }



  Future<void> _loadLocationOnce() async {
    try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
          ),
        );

        if (!mounted) return;

        setState(() {
        _latText = pos.latitude.toStringAsFixed(5);
        _lonText = pos.longitude.toStringAsFixed(5);
        _locErr = null;
        });

        await _loadWeather(pos.latitude, pos.longitude);
    } catch (e) {
        if (!mounted) return;
        setState(() {
        _locErr = e.toString();
        _latText = null;
        _lonText = null;

        _weatherCondition = null;
        _tempText = null;
        _weatherErr = null;
        });
    }
   }


  Future<void> _loadWeather(double lat, double lon) async {
    if (_weatherLoading) return;

    setState(() {
      _weatherLoading = true;
      _weatherErr = null;
      _weatherCondition = null;
      _tempText = null;
    });

    try {
      final svc = WeatherService(apiKey: openWeatherApiKey);
      final w = await svc.fetchCurrent(lat: lat, lon: lon, units: 'imperial');

      if (!mounted) return;
      setState(() {
        _weatherCondition = w.condition;
        _tempText = '${w.temperature.round()}°F';
        _weatherErr = null;
        _weatherLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _weatherErr = e.toString();
        _weatherLoading = false;
      });
    }
  }




  @override
  Widget build(BuildContext context) {

    // ---- UI-only mock values (replace with real backend later) ----
    const fatigueRisk = 42; // 0–100
    const status = "Normal";
    const driverId = "Sluggish Driver";
    const vehicle = "SlugMobile";

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'WAKE TF UP',
          style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 2.0),
        ),
        actions: [
            IconButton(
                onPressed: _loadLocationOnce,
                icon: const Icon(Icons.my_location),
            ),
        ],
      ),

      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            _HeaderCard(driverId: driverId, vehicle: vehicle),
            const SizedBox(height: 12),

            _RiskCard(value: fatigueRisk, label: status),
            const SizedBox(height: 12),

            Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                    const _StatusChip(label: "Face", value: "Detected"),
                    const _StatusChip(label: "Eyes", value: "Open"),
                    const _StatusChip(label: "Alert", value: "None"),
                    _StatusChip(
                      label: "Lat",
                      value: _latText ?? (_locErr == null ? "Loading…" : "Unavailable"),
                    ),
                    _StatusChip(
                      label: "Lon",
                      value: _lonText ?? (_locErr == null ? "Loading…" : "Unavailable"),
                    ),
                    _StatusChip(
                      label: "Weather",
                      value: _weatherCondition ?? (_weatherErr == null ? "Loading…" : "Unavailable"),
                    ),
                    _StatusChip(
                      label: "Temp",
                      value: _tempText ?? (_weatherErr == null ? "Loading…" : "Unavailable"),
                    ),
                ],
            ),


            const SizedBox(height: 12),

            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.35,
              children: const [
                // _MetricCard(title: "Blink Rate", value: "18", unit: "blinks/min"),
                // _MetricCard(title: "PERCLOS", value: "0.12", unit: "last 60s"),
                // _MetricCard(title: "Lane Risk", value: "0.35", unit: "0–1"),
                // _MetricCard(title: "Weather", value: "Clear", unit: "58°F"),
              ],
            ),

            const SizedBox(height: 20),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SizedBox(
            height: 64,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  Navigator.pushNamed(context, '/drowsiness-detected');
                },
                child: Center(
                  child: Text(
                    'DROWSINESS DETECTED',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.0,
                      color: _white(0.9),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

//// ---------------------------------------------------------------------------
//// Header Card
//// ---------------------------------------------------------------------------

class _HeaderCard extends StatelessWidget {
  final String driverId;
  final String vehicle;

  const _HeaderCard({
    required this.driverId,
    required this.vehicle,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.shield, size: 26),
            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    driverId,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    vehicle,
                    style: TextStyle(
                      color: _white(0.7),
                    ),
                  ),
                ],
              ),
            ),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _white(0.06),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: _white(0.12)),
              ),
              child: Text(
                "LIVE",
                style: TextStyle(
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                  color: _white(0.85),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//// ---------------------------------------------------------------------------
//// Fatigue Risk Card
//// ---------------------------------------------------------------------------

class _RiskCard extends StatelessWidget {
  final int value;
  final String label;

  const _RiskCard({
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0, 100);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 72,
              height: 72,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: v / 100.0,
                    strokeWidth: 6,
                    backgroundColor: Colors.white12,
                  ),
                  Center(
                    child: Text(
                      "$v%",
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _white(0.9),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 16),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Fatigue Risk",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(
                      color: _white(0.75),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Blink duration + lane behavior",
                    style: TextStyle(
                      color: _white(0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//// ---------------------------------------------------------------------------
//// Metric Card
//// ---------------------------------------------------------------------------

// ignore: unused_element
class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;

  const _MetricCard({
    required this.title,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: _white(0.7),
              ),
            ),

            const Spacer(),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    unit,
                    style: TextStyle(
                      color: _white(0.6),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// pill shaped status indicators

class _StatusChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatusChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final bg = _white(0.05);
    final border = _white(0.12);
    final fg = _white(0.85);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            "$label: ",
            style: TextStyle(color: _white(0.7)),
          ),
          Text(
            value,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
