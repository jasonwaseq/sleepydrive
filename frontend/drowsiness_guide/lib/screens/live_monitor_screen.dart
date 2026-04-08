import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/weather_service.dart';
import '../services/ble_service.dart';
import '../services/jetson_websocket_service.dart';
import '../secrets.dart';
import '../app.dart';

// -------------------- Color System --------------------

Color _black(double opacity) => Colors.black.withAlpha((opacity * 255).round());

const _accentBlue = Color(0xFF5E8AD6);
const _surface = Color(0xFFF7FAFF);
const _border = Color(0x1A000000);

// -----------------------------------------------------

class LiveMonitorScreen extends StatefulWidget {
  const LiveMonitorScreen({super.key});

  @override
  State<LiveMonitorScreen> createState() => _LiveMonitorScreenState();
}

class _LiveMonitorScreenState extends State<LiveMonitorScreen>
    with WidgetsBindingObserver {
  static const String _jetsonWsUrl = String.fromEnvironment(
    'JETSON_WS_URL',
    defaultValue: 'ws://localhost:8080/ws/alerts?replay=0',
  );
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

  // ── Jetson WebSocket ──
  final JetsonWebSocketService _jetsonWs = JetsonWebSocketService(
    uri: Uri.parse(_jetsonWsUrl),
  );
  String _jetsonWsState = 'Disconnected';
  StreamSubscription? _jetsonWsStateSub;
  StreamSubscription? _jetsonWsAlertSub;
  StreamSubscription? _jetsonPresenceSub;
  Timer? _jetsonPresenceTimer;

  String _latestAlertLevel = 'None';
  String _jetsonDeviceState = 'Offline';
  DateTime? _jetsonLastSeen;
  final List<_DashboardAlert> _alerts = [];
  static const Duration _jetsonStaleAfter = Duration(seconds: 30);

  bool _wsIsConnected(String s) => s == 'Connected';
  bool _wsIsBusy(String s) =>
      s.startsWith('Connecting…') || s.startsWith('Reconnecting…');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLocationOnce();

    // Listen for BLE connection state changes
    _bleStateSub = _ble.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => _bleState = state);
    });

    // Listen for BLE alerts and show notification dialog
    _bleAlertSub = _ble.alerts.listen((alert) {
      _handleIncomingAlert(
        level: alert.level,
        levelLabel: alert.levelLabel,
        message: alert.message,
        source: 'BLE',
      );
    });

    // Listen for Jetson WebSocket status + alerts
    _jetsonWsStateSub = _jetsonWs.connectionState.listen((state) {
      if (!mounted) return;
      setState(() => _jetsonWsState = state);
    });
    _jetsonWsAlertSub = _jetsonWs.alerts.listen((alert) {
      _handleIncomingAlert(
        level: alert.level,
        levelLabel: alert.levelLabel,
        message: alert.message,
        source: 'Jetson WS',
        alertTimestamp: alert.timestamp,
      );
    });
    _jetsonPresenceSub = _jetsonWs.presence.listen(_handleJetsonPresence);
    _startJetsonPresenceWatchdog();
    _jetsonWs.connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bleStateSub?.cancel();
    _bleAlertSub?.cancel();
    _jetsonWsStateSub?.cancel();
    _jetsonWsAlertSub?.cancel();
    _jetsonPresenceSub?.cancel();
    _jetsonPresenceTimer?.cancel();
    _ble.dispose();
    _jetsonWs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final isConnected =
          _wsIsConnected(_jetsonWsState) || _wsIsBusy(_jetsonWsState);
      if (!isConnected) {
        _jetsonWs.connect();
      }
    }
  }

  void _handleIncomingAlert({
    required int level,
    required String levelLabel,
    required String message,
    required String source,
    DateTime? alertTimestamp,
  }) {
    if (!mounted) return;
    setState(() {
      _latestAlertLevel = levelLabel;
      _alerts.insert(
        0,
        _DashboardAlert(
          level: level,
          levelLabel: levelLabel,
          message: message,
          source: source,
          timestamp: alertTimestamp ?? DateTime.now(),
        ),
      );
      if (_alerts.length > 12) {
        _alerts.removeRange(12, _alerts.length);
      }
    });
    _showAlertSnackBar(
      level: level,
      levelLabel: levelLabel,
      message: message,
      source: source,
    );
  }

  void _handleJetsonPresence(JetsonPresence presence) {
    if (!mounted) return;
    setState(() {
      _jetsonLastSeen = presence.timestamp;
      _jetsonDeviceState = presence.online ? 'Online' : 'Offline';
    });
  }

  void _startJetsonPresenceWatchdog() {
    _jetsonPresenceTimer?.cancel();
    _jetsonPresenceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final lastSeen = _jetsonLastSeen;
      final stale =
          lastSeen == null ||
          DateTime.now().difference(lastSeen) > _jetsonStaleAfter;
      if (stale && _jetsonDeviceState != 'Offline') {
        setState(() {
          _jetsonDeviceState = 'Offline';
        });
      }
    });
  }

  void _showAlertSnackBar({
    required int level,
    required String levelLabel,
    required String message,
    required String source,
  }) {
    if (!mounted) return;

    final bg = level >= 2
        ? const Color(0xFFB91C1C)
        : level == 1
        ? const Color(0xFFB45309)
        : const Color(0xFF1E3A8A);

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          backgroundColor: bg,
          content: Text('$levelLabel • $source: $message'),
        ),
      );
  }

  void _onBluetoothTap() async {
    if (_bleState == 'Connected') {
      await _ble.disconnect();
    } else if (_bleState == 'Disconnected' ||
        _bleState == 'Not found' ||
        _bleState == 'Connection failed') {
      await _ble.scanAndConnect();
    }
  }

  void _onJetsonWebSocketTap() async {
    final isActive =
        _wsIsConnected(_jetsonWsState) || _wsIsBusy(_jetsonWsState);
    if (isActive) {
      await _jetsonWs.disconnect();
    } else {
      await _jetsonWs.connect();
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
    final isDark = DriverSafetyApp.of(context).isDark;
    final bgTop = isDark ? const Color(0xFF0B1220) : const Color(0xFFCED8E4);
    final bgBottom = isDark ? const Color(0xFF0E1628) : const Color(0xFF7E97B9);
    final titleColor = isDark ? Colors.white : Colors.black;
    final iconColor = isDark ? Colors.white : Colors.black;
    const driverId = "Sluggish Driver";
    const vehicle = "SlugMobile";
    const fatigueRisk = 42;
    const status = "Normal";

    return Scaffold(
      backgroundColor: bgTop,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: iconColor),
        title: Text(
          'blink',
          style: TextStyle(
            color: titleColor,
            fontWeight: FontWeight.w600,
            letterSpacing: 2,
          ),
        ),
        actions: [
          IconButton(
            onPressed: _onBluetoothTap,
            tooltip: _bleState == 'Connected'
                ? 'Disconnect BLE'
                : 'Connect to SleepyDrive',
            icon: Icon(
              _bleState == 'Connected'
                  ? Icons.bluetooth_connected
                  : _bleState == 'Scanning…' || _bleState == 'Connecting…'
                  ? Icons.bluetooth_searching
                  : Icons.bluetooth,
              color: _bleState == 'Connected' ? _accentBlue : Colors.black,
            ),
          ),
          IconButton(
            onPressed: _onJetsonWebSocketTap,
            tooltip: _wsIsConnected(_jetsonWsState)
                ? 'Disconnect Jetson WebSocket'
                : 'Connect Jetson WebSocket',
            icon: Icon(
              _wsIsConnected(_jetsonWsState)
                  ? Icons.wifi_tethering
                  : _wsIsBusy(_jetsonWsState)
                  ? Icons.sync
                  : Icons.wifi_tethering_off,
              color: _wsIsConnected(_jetsonWsState)
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
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bgTop, bgBottom],
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
                  _StatusChip(label: "BLE", value: _bleState),
                  _StatusChip(label: "Jetson WS", value: _jetsonWsState),
                  _StatusChip(
                    label: "Jetson Device",
                    value: _jetsonDeviceState,
                  ),
                  const _StatusChip(label: "Face", value: "Detected"),
                  const _StatusChip(label: "Eyes", value: "Open"),
                  _StatusChip(label: "Alert", value: _latestAlertLevel),
                  _StatusChip(
                    label: "Lat",
                    value:
                        _latText ??
                        (_locErr == null ? "Loading…" : "Unavailable"),
                  ),
                  _StatusChip(
                    label: "Lon",
                    value:
                        _lonText ??
                        (_locErr == null ? "Loading…" : "Unavailable"),
                  ),
                  _StatusChip(
                    label: "Weather",
                    value:
                        _weatherCondition ??
                        (_weatherErr == null ? "Loading…" : "Unavailable"),
                  ),
                  _StatusChip(
                    label: "Temp",
                    value:
                        _tempText ??
                        (_weatherErr == null ? "Loading…" : "Unavailable"),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _AlertsCard(
                alerts: _alerts,
                wsState: _jetsonWsState,
                wsUrl: _jetsonWsUrl,
                onClear: () {
                  if (!mounted) return;
                  setState(() {
                    _alerts.clear();
                    _latestAlertLevel = 'None';
                  });
                },
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
                onTap: () =>
                    Navigator.pushNamed(context, '/map'),
                child: const Center(
                  child: Text(
                    'DROWSINESS DETECTED',
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
                  Text(vehicle, style: TextStyle(color: _black(0.6))),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _accentBlue.withValues(alpha: 0.12),
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
            style: TextStyle(color: _black(0.8), fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _DashboardAlert {
  final int level;
  final String levelLabel;
  final String message;
  final String source;
  final DateTime timestamp;

  const _DashboardAlert({
    required this.level,
    required this.levelLabel,
    required this.message,
    required this.source,
    required this.timestamp,
  });
}

class _AlertsCard extends StatelessWidget {
  final List<_DashboardAlert> alerts;
  final String wsState;
  final String wsUrl;
  final VoidCallback onClear;

  const _AlertsCard({
    required this.alerts,
    required this.wsState,
    required this.wsUrl,
    required this.onClear,
  });

  Color _levelColor(int level) {
    if (level >= 2) return const Color(0xFFEF4444);
    if (level == 1) return const Color(0xFFF59E0B);
    return _accentBlue;
  }

  IconData _levelIcon(int level) {
    if (level >= 2) return Icons.warning_rounded;
    if (level == 1) return Icons.error_outline;
    return Icons.info_outline;
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.notifications_active_outlined,
                  color: _accentBlue,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Live Alerts',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _black(0.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    wsState,
                    style: TextStyle(
                      color: _black(0.7),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (alerts.isNotEmpty)
                  TextButton(onPressed: onClear, child: const Text('Clear')),
              ],
            ),
            const SizedBox(height: 6),
            Text(wsUrl, style: TextStyle(color: _black(0.52), fontSize: 11)),
            const SizedBox(height: 8),
            if (alerts.isEmpty)
              Text(
                'No alerts yet. Incoming BLE or Jetson WebSocket alerts will appear here.',
                style: TextStyle(color: _black(0.58)),
              )
            else
              SizedBox(
                height: 170,
                child: ListView.separated(
                  itemCount: alerts.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 10, color: _border),
                  itemBuilder: (context, i) {
                    final a = alerts[i];
                    final c = _levelColor(a.level);
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_levelIcon(a.level), color: c, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${a.levelLabel} • ${a.source} • ${_formatTime(a.timestamp)}',
                                style: TextStyle(
                                  color: c,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                a.message,
                                style: TextStyle(color: _black(0.76)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
