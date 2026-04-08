import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/weather_service.dart';
import '../services/ble_service.dart';
import '../secrets.dart';

// -------------------- Color System --------------------

Color _black(double opacity) => Colors.black.withAlpha((opacity * 255).round());

const _accentBlue = Color(0xFF5E8AD6);
const _bgTop = Color(0xFFCED8E4);
const _bgBottom = Color(0xFF7E97B9);
const _surface = Color(0xFFF7FAFF);
const _border = Color(0x1A000000);

// -----------------------------------------------------

class DrowsinessDetectedScreen extends StatefulWidget {
  const DrowsinessDetectedScreen({super.key});

  @override
  State<DrowsinessDetectedScreen> createState() =>
      _DrowsinessDetectedScreenState();
}

class _DrowsinessDetectedScreenState extends State<DrowsinessDetectedScreen> {
  String? _latText;
  String? _lonText;
  String? _locErr;

  String? _weatherCondition;
  String? _tempText;
  String? _weatherErr;

  bool _weatherLoading = false;

  // ── BLE ──
  final BleService _ble = BleService();
  String _bleState = 'Disconnected';
  StreamSubscription? _bleStateSub;
  StreamSubscription? _bleAlertSub;

  @override
  void initState() {
    super.initState();
    _loadLocationOnce();

    // Listen for BLE connection state changes
    _bleStateSub = _ble.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => _bleState = state);
    });

    // Listen for BLE alerts and show notification dialog
    _bleAlertSub = _ble.alerts.listen(_showAlertNotification);
  }

  @override
  void dispose() {
    _bleStateSub?.cancel();
    _bleAlertSub?.cancel();
    _ble.dispose();
    super.dispose();
  }

  void _showAlertNotification(BleAlert alert) {
    if (!mounted) return;

    final isWarning = alert.level == 1;
    final isDanger = alert.level >= 2;
    final color = isDanger
        ? const Color(0xFFEF4444)
        : isWarning
            ? const Color(0xFFF59E0B)
            : _accentBlue;
    final icon = isDanger ? Icons.warning_rounded : Icons.info_outline;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2332),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: color, width: 2),
        ),
        icon: Icon(icon, color: color, size: 48),
        title: Text(
          alert.levelLabel,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
          ),
        ),
        content: Text(
          alert.message,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('OK', style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  void _onBluetoothTap() async {
    if (_bleState == 'Connected') {
      await _ble.disconnect();
    } else if (_bleState == 'Disconnected' || _bleState == 'Not found' || _bleState == 'Connection failed') {
      await _ble.scanAndConnect();
    }
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
        _weatherLoading = false;
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
    const driverId = "Sluggish Driver";
    const vehicle = "SlugMobile";
    const fatigueRisk = 42;
    const status = "Normal";

    return Scaffold(
      backgroundColor: _bgTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.black),
        title: const Text(
          'blink',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _onBluetoothTap,
            tooltip: _bleState == 'Connected' ? 'Disconnect BLE' : 'Connect to SleepyDrive',
            icon: Icon(
              _bleState == 'Connected'
                  ? Icons.bluetooth_connected
                  : _bleState == 'Scanning…' || _bleState == 'Connecting…'
                      ? Icons.bluetooth_searching
                      : Icons.bluetooth,
              color: _bleState == 'Connected'
                  ? _accentBlue
                  : Colors.black,
            ),
          ),
          IconButton(
            onPressed: _loadLocationOnce,
            icon: const Icon(Icons.my_location, color: Colors.black),
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
        child: Padding(
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
                  _StatusChip(
                    label: "BLE",
                    value: _bleState,
                  ),
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
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SizedBox(
            height: 60,
            child: Container(
              decoration: BoxDecoration(
                color: _accentBlue,
                borderRadius: BorderRadius.circular(16),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.pushNamed(context, '/map'),
                child: const Center(
                  child: Text(
                    'OPEN MAP',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
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

// -------------------- Components --------------------

class _HeaderCard extends StatelessWidget {
  final String driverId;
  final String vehicle;

  const _HeaderCard({required this.driverId, required this.vehicle});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: _surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.shield, color: _accentBlue),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Driver",
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    driverId,
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    vehicle,
                    style: TextStyle(color: _black(0.6)),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _accentBlue.withOpacity(0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                "LIVE",
                style: TextStyle(
                  color: _accentBlue,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskCard extends StatelessWidget {
  final int value;
  final String label;

  const _RiskCard({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0, 100);

    return Card(
      color: _surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: _border),
      ),
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
                    color: _accentBlue,
                    backgroundColor: _black(0.08),
                  ),
                  Center(
                    child: Text(
                      "$v%",
                      style: TextStyle(
                        color: _black(0.8),
                        fontWeight: FontWeight.w700,
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
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(label, style: TextStyle(color: _black(0.65))),
                  const SizedBox(height: 8),
                  Text(
                    "Blink duration + lane behavior",
                    style: TextStyle(color: _black(0.5)),
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

class _StatusChip extends StatelessWidget {
  final String label;
  final String value;

  const _StatusChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _border), // <-- not const (works across SDKs)
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _accentBlue,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text("$label: ", style: TextStyle(color: _black(0.55))),
          Text(
            value,
            style: TextStyle(
              color: _black(0.8),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
