import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../services/weather_service.dart';
import '../services/ble_service.dart';
import '../services/jetson_websocket_service.dart';
import '../services/user_role_service.dart';
import '../secrets.dart';
import '../services/auth_service.dart';

// -------------------- Color System --------------------

Color _black(double opacity) => Colors.black.withAlpha((opacity * 255).round());

const _accentBlue = Color(0xFF5E8AD6);
const _surface = Color(0xFFF7FAFF);
const _border = Color(0x1A000000);

// -----------------------------------------------------

class LiveMonitorScreen extends StatefulWidget {
  const LiveMonitorScreen({super.key, this.bleService, this.jetsonWsService});

  final BleService? bleService;
  final JetsonWebSocketService? jetsonWsService;

  @override
  State<LiveMonitorScreen> createState() => _LiveMonitorScreenState();
}

class _LiveMonitorScreenState extends State<LiveMonitorScreen>
    with WidgetsBindingObserver {
  static const String _jetsonWsUrl = String.fromEnvironment(
    'JETSON_WS_URL',
    defaultValue: 'ws://localhost:8080/ws/alerts?replay=0',
  );
  static const int _fatigueRiskResetValue = 0;
  static const int _fatigueRiskStep = 10;
  static const int _fatigueRampStep = 2;
  static const int _fatigueRecoveryStep = 2;
  static const Duration _fatigueRampInterval = Duration(seconds: 2);

  String? _fleetName;
  String? _displayName;

  String? _cityText;
  String? _locErr;

  String? _weatherCondition;
  String? _tempText;
  String? _weatherErr;

  bool _weatherLoading = false;

  // ── BLE ──
  late BleService _ble;
  String _bleState = kIsWeb ? 'Tap Bluetooth' : 'Disconnected';
  StreamSubscription? _bleStateSub;
  StreamSubscription? _bleAlertSub;

  // ── Jetson WebSocket ──
  late JetsonWebSocketService _jetsonWs;
  String _jetsonWsState = 'Disconnected';
  StreamSubscription? _jetsonWsStateSub;
  StreamSubscription? _jetsonWsAlertSub;
  StreamSubscription? _jetsonPresenceSub;
  Timer? _jetsonPresenceTimer;
  Timer? _fatigueRampTimer;

  String _latestAlertLevel = 'None';
  String _jetsonDeviceState = 'Offline';
  int _fatigueRisk = _fatigueRiskResetValue;
  bool _hasUnrecoveredJetsonAlert = false;
  DateTime? _jetsonLastSeen;
  final List<_DashboardAlert> _alerts = [];
  static const Duration _jetsonStaleAfter = Duration(seconds: 30);

  bool _wsIsConnected(String s) => s == 'Connected';
  bool _wsIsBusy(String s) =>
      s.startsWith('Connecting…') || s.startsWith('Reconnecting…');

  String get _fatigueRiskStatus {
    if (_fatigueRisk >= 90) return 'Extreme fatigue';
    if (_fatigueRisk >= 70) return 'Critical fatigue';
    if (_fatigueRisk >= 50) return 'High fatigue';
    if (_fatigueRisk >= 30) return 'Moderate fatigue';
    if (_fatigueRisk >= 10) return 'Low fatigue';
    return 'No fatigue';
  }

  @override
  void initState() {
    super.initState();
    _ble = widget.bleService ?? BleService();
    _jetsonWs =
        widget.jetsonWsService ??
        JetsonWebSocketService(uri: Uri.parse(_jetsonWsUrl));
    WidgetsBinding.instance.addObserver(this);
    _loadLocationOnce();
    _loadProfile();

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
    if (!kIsWeb) {
      unawaited(_ble.scanAndConnect());
    }

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
        fatigueRiskPercent: alert.fatigueRiskPercent,
        recovered: alert.recovered,
      );
    });
    _jetsonPresenceSub = _jetsonWs.presence.listen(_handleJetsonPresence);
    _startJetsonPresenceWatchdog();
    _startFatigueRampTimer();
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
    _fatigueRampTimer?.cancel();
    _ble.dispose();
    _jetsonWs.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final wsConnected =
          _wsIsConnected(_jetsonWsState) || _wsIsBusy(_jetsonWsState);
      if (!wsConnected) {
        _jetsonWs.connect();
      }
      // OS kills BLE in background on many Android devices — reconnect on resume.
      if (!kIsWeb &&
          _bleState != 'Connected' &&
          _bleState != 'Scanning…' &&
          _bleState != 'Connecting…' &&
          _bleState != 'Select SleepyDrive…' &&
          _bleState != 'Waiting for Bluetooth…') {
        unawaited(_ble.scanAndConnect());
      }
    }
  }

  void _handleIncomingAlert({
    required int level,
    required String levelLabel,
    required String message,
    required String source,
    DateTime? alertTimestamp,
    int? fatigueRiskPercent,
    bool? recovered,
  }) {
    if (!mounted) return;
    setState(() {
      _latestAlertLevel = levelLabel;
      final isJetson = source == 'Jetson WS';
      final bool isRecovered = isJetson
          ? (recovered ?? _messageLooksRecovered(message) || level == 0)
          : false;
      final bool isUnrecovered = isJetson && !isRecovered;

      if (isRecovered) {
        _hasUnrecoveredJetsonAlert = false;
      } else if (isUnrecovered) {
        _hasUnrecoveredJetsonAlert = true;
      }

      if (fatigueRiskPercent != null) {
        _fatigueRisk = fatigueRiskPercent.clamp(0, 100).toInt();
      } else if (!isJetson || isUnrecovered) {
        final nextRisk = _fatigueRisk + _fatigueRiskStep;
        _fatigueRisk = nextRisk.clamp(0, 100).toInt();
      }
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
      final nextState = presence.online ? 'Online' : 'Offline';
      if (_jetsonDeviceState != nextState && nextState == 'Offline') {
        _fatigueRisk = _fatigueRiskResetValue;
        _hasUnrecoveredJetsonAlert = false;
      } else if (presence.online && presence.fatigueRiskPercent != null) {
        _fatigueRisk = presence.fatigueRiskPercent!.clamp(0, 100).toInt();
      }
      _jetsonDeviceState = nextState;
    });
  }

  void _startFatigueRampTimer() {
    _fatigueRampTimer?.cancel();
    _fatigueRampTimer = Timer.periodic(_fatigueRampInterval, (_) {
      if (!mounted) return;
      if (_jetsonDeviceState != 'Online') return;
      setState(() {
        if (_hasUnrecoveredJetsonAlert) {
          if (_fatigueRisk < 100) {
            _fatigueRisk = (_fatigueRisk + _fatigueRampStep)
                .clamp(0, 100)
                .toInt();
          }
          return;
        }
        if (_fatigueRisk > 0) {
          _fatigueRisk = (_fatigueRisk - _fatigueRecoveryStep)
              .clamp(0, 100)
              .toInt();
        }
      });
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
          _fatigueRisk = _fatigueRiskResetValue;
          _hasUnrecoveredJetsonAlert = false;
          _jetsonDeviceState = 'Offline';
        });
      }
    });
  }

  bool _messageLooksRecovered(String message) {
    final text = message.trim().toLowerCase();
    if (text.isEmpty) return false;
    return text.contains('recover') ||
        text.contains('resolved') ||
        text.contains('clear') ||
        text.contains('back to normal') ||
        text.contains('attentive again');
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
    } else if (_bleState != 'Scanning…' &&
        _bleState != 'Connecting…' &&
        _bleState != 'Select SleepyDrive…' &&
        _bleState != 'Waiting for Bluetooth…') {
      await _ble.scanAndConnect(userInitiated: true);
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
        _cityText = null;
        _locErr = null;
      });

      await _loadWeather(pos.latitude, pos.longitude);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locErr = e.toString();
        _cityText = null;
        _weatherCondition = null;
        _tempText = null;
        _weatherErr = null;
        _weatherLoading = false;
      });
    }
  }

  Future<void> _loadProfile() async {
    User? user;
    try {
      user = FirebaseAuth.instance.currentUser;
    } catch (_) {
      return;
    }
    if (user == null) return;
    try {
      final profile = await UserRoleService().fetchProfile(user.uid);
      if (!mounted) return;
      setState(() {
        _fleetName = profile?.fleetName;
        _displayName = profile?.displayName;
      });
    } catch (_) {}
  }

  Future<void> _showEditProfileDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final current = _displayName ?? '';
    final parts = current.split(' ');
    final firstCtrl = TextEditingController(
      text: parts.isNotEmpty ? parts.first : '',
    );
    final lastCtrl = TextEditingController(
      text: parts.length > 1 ? parts.sublist(1).join(' ') : '',
    );
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Edit profile'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: firstCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'First name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: lastCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Last name'),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final first = firstCtrl.text.trim();
                final last = lastCtrl.text.trim();
                final fullName = [
                  first,
                  last,
                ].where((s) => s.isNotEmpty).join(' ');
                if (fullName.isEmpty) {
                  setDialogState(
                    () => errorText = 'Please enter at least a first name.',
                  );
                  return;
                }
                try {
                  await UserRoleService().saveRole(
                    uid: user.uid,
                    role: 'driver',
                    email: user.email,
                    displayName: fullName,
                  );
                  if (!mounted) return;
                  setState(() => _displayName = fullName);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  setDialogState(
                    () => errorText = e.toString().replaceFirst(
                      'Exception: ',
                      '',
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    firstCtrl.dispose();
    lastCtrl.dispose();
  }

  Future<void> _showJoinFleetDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _JoinFleetDialog(
        onJoin: (code) async {
          final user = FirebaseAuth.instance.currentUser;
          if (user == null) return;
          await UserRoleService().saveRole(
            uid: user.uid,
            role: 'driver',
            fleetInviteCode: code,
          );
        },
        onSuccess: () {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Fleet joined successfully')),
          );
          _loadProfile();
        },
        onError: (message) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        },
      ),
    );
  }

  Future<void> _backToLogin() async {
    await AuthService().signOut();

    if (!mounted) return;

    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
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
        _cityText = w.city;
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
    const bgTop = Color(0xFFCED8E4);
    const bgBottom = Color(0xFF7E97B9);
    const titleColor = Colors.black;
    const iconColor = Colors.black;

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
            onPressed: _showEditProfileDialog,
            tooltip: 'Edit profile',
            icon: Icon(Icons.account_circle, color: iconColor),
          ),
          IconButton(
            onPressed: _onBluetoothTap,
            tooltip: _bleState == 'Connected'
                ? 'Disconnect BLE'
                : 'Connect to SleepyDrive',
            icon: Icon(
              _bleState == 'Connected'
                  ? Icons.bluetooth_connected
                  : _bleState == 'Scanning…' ||
                        _bleState == 'Connecting…' ||
                        _bleState == 'Select SleepyDrive…'
                  ? Icons.bluetooth_searching
                  : Icons.bluetooth,
              color: _bleState == 'Connected' ? _accentBlue : iconColor,
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
              color: _wsIsConnected(_jetsonWsState) ? _accentBlue : iconColor,
            ),
          ),
          IconButton(
            onPressed: _showJoinFleetDialog,
            tooltip: 'Join a fleet',
            icon: Icon(Icons.group_add, color: iconColor),
          ),
          IconButton(
            onPressed: _loadLocationOnce,
            icon: Icon(Icons.my_location, color: iconColor),
          ),
          IconButton(
            onPressed: _backToLogin,
            tooltip: 'Back to login',
            icon: Icon(Icons.logout, color: iconColor),
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
              _HeaderCard(
                displayName: _displayName,
                fleetName: _fleetName,
                isOnline: _jetsonDeviceState == 'Online',
              ),
              const SizedBox(height: 12),
              _RiskCard(value: _fatigueRisk, label: _fatigueRiskStatus),
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
                  _StatusChip(label: "Alert", value: _latestAlertLevel),
                  _StatusChip(
                    label: "City",
                    value:
                        _cityText ??
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
                onTap: () => Navigator.pushNamed(context, '/map'),
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
  final String? displayName;
  final String? fleetName;
  final bool isOnline;

  const _HeaderCard({this.displayName, this.fleetName, required this.isOnline});

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
                    displayName ?? '—',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (fleetName != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.local_shipping_rounded,
                          size: 13,
                          color: _black(0.45),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          fleetName!,
                          style: TextStyle(color: _black(0.55), fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isOnline
                    ? const Color(0xFF10B981)
                    : const Color(0xFFEF4444),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                isOnline ? 'Online' : 'Offline',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  fontSize: 13,
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

class _JoinFleetDialog extends StatefulWidget {
  final Future<void> Function(String code) onJoin;
  final VoidCallback onSuccess;
  final void Function(String message) onError;

  const _JoinFleetDialog({
    required this.onJoin,
    required this.onSuccess,
    required this.onError,
  });

  @override
  State<_JoinFleetDialog> createState() => _JoinFleetDialogState();
}

class _JoinFleetDialogState extends State<_JoinFleetDialog> {
  final _ctrl = TextEditingController();
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _ctrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter an invite code');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      await widget.onJoin(code);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onSuccess();
    } on UserRoleServiceException catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      widget.onError(e.message);
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context);
      widget.onError('Could not join fleet. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a Fleet'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter the invite code from your fleet operator.'),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'Invite code',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _loading ? null : _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Join'),
        ),
      ],
    );
  }
}
