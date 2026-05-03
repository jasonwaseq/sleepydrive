import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drowsiness_guide/services/jetson_websocket_service.dart';
import 'package:drowsiness_guide/services/auth_service.dart';
import 'package:drowsiness_guide/services/user_role_service.dart';

class FleetOperatorDashboard extends StatefulWidget {
  const FleetOperatorDashboard({super.key});

  @override
  State<FleetOperatorDashboard> createState() => _FleetOperatorDashboardState();
}

class _FleetOperatorDashboardState extends State<FleetOperatorDashboard> {
  static const int _fatigueRiskStep = 10;
  static const int _fatigueRampStep = 2;
  static const Duration _fatigueRampInterval = Duration(seconds: 2);

  static const String _jetsonWsUrl = String.fromEnvironment(
    'JETSON_WS_URL',
    defaultValue: 'ws://localhost:8080/ws/alerts?replay=0',
  );

  late final JetsonWebSocketService _jetsonWs = JetsonWebSocketService(
    uri: Uri.parse(_jetsonWsUrl),
  );
  final UserRoleService _userRoleService = UserRoleService();
  final ValueNotifier<int> _liveAlertsVersion = ValueNotifier<int>(0);

  StreamSubscription<JetsonAlert>? _alertSub;
  StreamSubscription<JetsonPresence>? _presenceSub;
  StreamSubscription<String>? _stateSub;
  Timer? _fleetPollTimer;
  Timer? _fleetRefreshDebounce;
  Timer? _fatigueRampTimer;

  String _wsState = 'Disconnected';
  String? _fleetName;
  String? _fleetInviteCode;
  String? _fleetLoadError;
  bool _isLoadingFleet = true;
  bool _isRefreshingFleet = false;

  final Map<String, _DriverData> _driversByUid = {};
  final Map<String, List<FleetAlert>> _liveAlertsByUid = {};
  final Map<String, bool> _activeFatigueByUid = {};

  @override
  void initState() {
    super.initState();

    _stateSub = _jetsonWs.connectionState.listen((state) {
      if (!mounted) return;
      setState(() {
        _wsState = state;
      });
    });

    _alertSub = _jetsonWs.alerts.listen(_handleAlert);
    _presenceSub = _jetsonWs.presence.listen(_handlePresence);

    _loadFleetDrivers();
    _jetsonWs.connect();
    _startFatigueRampTimer();
    _fleetPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _refreshFleetDrivers();
    });
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _presenceSub?.cancel();
    _stateSub?.cancel();
    _fleetPollTimer?.cancel();
    _fleetRefreshDebounce?.cancel();
    _fatigueRampTimer?.cancel();
    _liveAlertsVersion.dispose();
    _jetsonWs.dispose();
    super.dispose();
  }

  void _handleAlert(JetsonAlert alert) {
    if (!mounted) return;

    setState(() {
      final entries = _entriesForCandidates(
        _alertMatchCandidates(alert),
        allowSingleDriverFallback: true,
      );
      if (entries.isEmpty) {
        return;
      }

      for (final entry in entries) {
        final isRecovered =
            alert.recovered ?? _alertMessageLooksRecovered(alert.message);
        if (isRecovered) {
          _activeFatigueByUid[entry.key] = false;
        } else {
          _activeFatigueByUid[entry.key] = true;
        }

        final int updatedRisk;
        if (alert.fatigueRiskPercent != null) {
          updatedRisk = alert.fatigueRiskPercent!.clamp(0, 100).toInt();
        } else if (isRecovered) {
          updatedRisk = entry.value.risk;
        } else {
          updatedRisk = (entry.value.risk + _fatigueRiskStep).clamp(0, 100);
        }
        _addLiveAlert(entry.key, alert);
        _driversByUid[entry.key] = entry.value.copyWith(
          risk: updatedRisk,
          status: _statusFromRiskValue(updatedRisk),
          isOnline: true,
          hasFatigueData: true,
          alertCount: entry.value.alertCount + 1,
          lastAlert: alert.message,
          lastUpdated: alert.timestamp,
        );
      }
    });
    _scheduleFleetRefresh();
  }

  void _addLiveAlert(String driverUid, JetsonAlert alert) {
    final liveAlerts = _liveAlertsByUid.putIfAbsent(
      driverUid,
      () => <FleetAlert>[],
    );
    liveAlerts.insert(
      0,
      FleetAlert(
        level: alert.level,
        message: alert.message,
        timestamp: alert.timestamp,
        metadata: alert.metadata,
        fatigueRiskPercent: alert.fatigueRiskPercent,
      ),
    );
    if (liveAlerts.length > 50) {
      liveAlerts.removeRange(50, liveAlerts.length);
    }
    _liveAlertsVersion.value++;
  }

  void _handlePresence(JetsonPresence presence) {
    if (!mounted) return;

    setState(() {
      final entries = _entriesForCandidates(
        _presenceMatchCandidates(presence),
        allowSingleDriverFallback: true,
      );
      if (entries.isEmpty) {
        return;
      }

      for (final entry in entries) {
        final updatedRisk = presence.fatigueRiskPercent;
        if (!presence.online) {
          _activeFatigueByUid[entry.key] = false;
        }
        if (updatedRisk != null) {
          _driversByUid[entry.key] = entry.value.copyWith(
            isOnline: presence.online,
            risk: updatedRisk,
            status: _statusFromRiskValue(updatedRisk),
            hasFatigueData: true,
            lastUpdated: presence.timestamp,
          );
        } else {
          _driversByUid[entry.key] = entry.value.copyWith(
            isOnline: presence.online,
            lastUpdated: presence.timestamp,
          );
        }
      }
    });
    _scheduleFleetRefresh();
  }

  List<_DriverData> get _sortedDrivers {
    final list = _driversByUid.values.toList()
      ..sort((a, b) {
        final riskCompare = b.risk.compareTo(a.risk);
        if (riskCompare != 0) return riskCompare;
        if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
        return a.displayName.compareTo(b.displayName);
      });
    return list;
  }

  List<MapEntry<String, _DriverData>> _entriesForCandidates(
    Iterable<String?> candidates, {
    bool allowSingleDriverFallback = false,
  }) {
    final normalizedCandidates = candidates
        .map(_normalizeMatchValue)
        .where((value) => value.isNotEmpty)
        .toSet();
    final matches = <MapEntry<String, _DriverData>>[];
    if (normalizedCandidates.isEmpty) return matches;

    for (final entry in _driversByUid.entries) {
      final driver = entry.value;
      final driverValues = {
        _normalizeMatchValue(driver.uid),
        _normalizeMatchValue(driver.deviceId),
        _normalizeMatchValue(driver.email),
        _normalizeMatchValue(driver.displayName),
      };
      if (driverValues.any(normalizedCandidates.contains)) {
        matches.add(entry);
      }
    }
    if (matches.isEmpty &&
        allowSingleDriverFallback &&
        _driversByUid.length == 1) {
      return [_driversByUid.entries.first];
    }
    return matches;
  }

  List<String?> _alertMatchCandidates(JetsonAlert alert) {
    return [
      alert.deviceId,
      alert.metadata['device_id']?.toString(),
      alert.metadata['source_id']?.toString(),
      alert.metadata['driver_uid']?.toString(),
      alert.metadata['uid']?.toString(),
      alert.metadata['email']?.toString(),
      alert.metadata['driver_email']?.toString(),
    ];
  }

  List<String?> _presenceMatchCandidates(JetsonPresence presence) {
    return [
      presence.sourceId,
      presence.metadata['device_id']?.toString(),
      presence.metadata['source_id']?.toString(),
      presence.metadata['driver_uid']?.toString(),
      presence.metadata['uid']?.toString(),
      presence.metadata['email']?.toString(),
      presence.metadata['driver_email']?.toString(),
    ];
  }

  String _normalizeMatchValue(String? value) {
    return (value ?? '').trim().toLowerCase();
  }

  Future<void> _loadFleetDrivers() async {
    setState(() {
      _isLoadingFleet = true;
      _fleetLoadError = null;
    });

    try {
      final data = await _userRoleService.fetchFleetDashboard();
      _applyFleetDashboardData(data);
    } on UserRoleServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _fleetLoadError = e.toString().replaceFirst('Exception: ', '');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fleetLoadError = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingFleet = false;
        });
      }
    }
  }

  void _scheduleFleetRefresh() {
    _fleetRefreshDebounce?.cancel();
    _fleetRefreshDebounce = Timer(const Duration(milliseconds: 350), () {
      _refreshFleetDrivers();
    });
  }

  void _startFatigueRampTimer() {
    _fatigueRampTimer?.cancel();
    _fatigueRampTimer = Timer.periodic(_fatigueRampInterval, (_) {
      if (!mounted || _driversByUid.isEmpty) return;

      var changed = false;
      final now = DateTime.now();
      for (final entry in _driversByUid.entries.toList()) {
        final uid = entry.key;
        final driver = entry.value;
        final isActive = _activeFatigueByUid[uid] ?? false;
        if (!isActive || !driver.isOnline || !driver.hasFatigueData) continue;
        if (driver.risk >= 100) continue;

        final nextRisk = (driver.risk + _fatigueRampStep).clamp(0, 100);
        _driversByUid[uid] = driver.copyWith(
          risk: nextRisk,
          status: _statusFromRiskValue(nextRisk),
          lastUpdated: now,
        );
        changed = true;
      }

      if (changed && mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _refreshFleetDrivers() async {
    if (_isRefreshingFleet || _isLoadingFleet) return;
    _isRefreshingFleet = true;
    try {
      final data = await _userRoleService.fetchFleetDashboard();
      _applyFleetDashboardData(data);
      if (!mounted) return;
      setState(() {
        _fleetLoadError = null;
      });
    } catch (_) {
      // Keep the current dashboard visible during background refresh failures.
    } finally {
      _isRefreshingFleet = false;
    }
  }

  void _applyFleetDashboardData(FleetDashboardData data) {
    if (!mounted) return;

    setState(() {
      _fleetName = data.fleet.name;
      _fleetInviteCode = data.fleet.inviteCode;
      final previousDrivers = Map<String, _DriverData>.from(_driversByUid);
      _driversByUid
        ..clear()
        ..addEntries(
          data.drivers.map((driver) {
            final next = _DriverData.fromFleetDriver(driver);
            final previous = previousDrivers[driver.uid];
            return MapEntry(
              driver.uid,
              previous == null ? next : _mergeDriverData(previous, next),
            );
          }),
        );
      final beforePrune = _liveAlertsByUid.length;
      _liveAlertsByUid.removeWhere((uid, _) => !_driversByUid.containsKey(uid));
      _activeFatigueByUid.removeWhere(
        (uid, _) => !_driversByUid.containsKey(uid),
      );
      if (_liveAlertsByUid.length != beforePrune) {
        _liveAlertsVersion.value++;
      }
    });
  }

  Future<void> _backToLogin() async {
    await AuthService().signOut();

    if (!mounted) return;

    Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
  }

  Future<void> _removeDriver(_DriverData driver) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove driver?'),
        content: Text(
          '${driver.displayName} will be removed from your fleet. '
          'They can rejoin with an invite code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await _userRoleService.removeDriver(driver.uid);
      if (!mounted) return;
      setState(() {
        _driversByUid.remove(driver.uid);
        if (_liveAlertsByUid.remove(driver.uid) != null) {
          _liveAlertsVersion.value++;
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${driver.displayName} removed from fleet')),
      );
    } on UserRoleServiceException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    const bgTop = Color(0xFFCED8E4);
    const bgBottom = Color(0xFF7E97B9);

    final sortedDrivers = _sortedDrivers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Dashboard'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _ConnectionBadge(state: _wsState)),
          ),
          IconButton(
            onPressed: _isLoadingFleet ? null : _loadFleetDrivers,
            tooltip: 'Refresh fleet',
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _backToLogin,
            tooltip: 'Back to login',
            icon: const Icon(Icons.logout),
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
          child: Column(
            children: [
              if (_fleetName != null || _fleetInviteCode != null) ...[
                _FleetHeader(
                  fleetName: _fleetName ?? 'Fleet',
                  inviteCode: _fleetInviteCode,
                ),
                const SizedBox(height: 12),
              ],
              _SummaryRow(drivers: sortedDrivers),
              const SizedBox(height: 16),
              Expanded(
                child: _isLoadingFleet
                    ? const Center(child: CircularProgressIndicator())
                    : _fleetLoadError != null
                    ? _FleetLoadError(
                        message: _fleetLoadError!,
                        onRetry: _loadFleetDrivers,
                      )
                    : sortedDrivers.isEmpty
                    ? _EmptyFleetState(inviteCode: _fleetInviteCode)
                    : ListView.builder(
                        itemCount: sortedDrivers.length,
                        itemBuilder: (context, i) {
                          final driver = sortedDrivers[i];
                          return AnimatedContainer(
                            key: ValueKey(driver.uid),
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                            child: _DriverCard(
                              driver: driver,
                              rank: i + 1,
                              onViewAlerts: () => _showDriverAlerts(driver),
                              onRemove: () => _removeDriver(driver),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDriverAlerts(_DriverData driver) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final alertsFuture = _userRoleService.fetchDriverAlerts(driver.uid);
        return ValueListenableBuilder<int>(
          valueListenable: _liveAlertsVersion,
          builder: (context, _, child) {
            final currentDriver = _driversByUid[driver.uid] ?? driver;
            return FutureBuilder<List<FleetAlert>>(
              future: alertsFuture,
              builder: (context, snapshot) {
                final alerts = _combinedDriverAlerts(
                  driver.uid,
                  snapshot.data ?? const <FleetAlert>[],
                );

                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.person_rounded),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    currentDriver.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  if (currentDriver.deviceId != null)
                                    Text(
                                      'Device: ${currentDriver.deviceId}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (currentDriver.email != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            currentDriver.email!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (snapshot.connectionState ==
                                ConnectionState.waiting &&
                            alerts.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (snapshot.hasError && alerts.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              snapshot.error.toString(),
                              style: const TextStyle(color: Color(0xFFFF6B6B)),
                            ),
                          )
                        else if (alerts.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('No alerts recorded for this driver.'),
                          )
                        else
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.48,
                            ),
                            child: ListView.separated(
                              shrinkWrap: true,
                              itemCount: alerts.length,
                              separatorBuilder: (context, index) =>
                                  const Divider(),
                              itemBuilder: (context, index) {
                                final alert = alerts[index];
                                final color = _alertLevelColor(alert.level);
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    Icons.warning_rounded,
                                    color: color,
                                  ),
                                  title: Text(alert.message),
                                  subtitle: Text(
                                    _formatAlertTime(alert.timestamp),
                                  ),
                                  trailing: Text(
                                    _alertLevelLabel(alert.level),
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  List<FleetAlert> _combinedDriverAlerts(
    String driverUid,
    List<FleetAlert> serverAlerts,
  ) {
    final liveAlerts = _liveAlertsByUid[driverUid] ?? const <FleetAlert>[];
    if (liveAlerts.isEmpty) return serverAlerts;

    final seen = <String>{};
    final merged = <FleetAlert>[];
    for (final alert in [...liveAlerts, ...serverAlerts]) {
      final key = [
        alert.level,
        alert.message,
        alert.timestamp?.millisecondsSinceEpoch ?? 0,
      ].join('|');
      if (seen.add(key)) {
        merged.add(alert);
      }
    }
    return merged;
  }
}

bool _alertMessageLooksRecovered(String message) {
  final text = message.trim().toLowerCase();
  if (text.isEmpty) return false;
  return text.contains('recover') ||
      text.contains('resolved') ||
      text.contains('clear') ||
      text.contains('back to normal') ||
      text.contains('attentive again');
}

class _DriverData {
  final String uid;
  final String displayName;
  final String? email;
  final String? deviceId;
  final int risk;
  final String status;
  final bool isOnline;
  final bool hasFatigueData;
  final int alertCount;
  final String? lastAlert;
  final DateTime? lastUpdated;

  const _DriverData({
    required this.uid,
    required this.displayName,
    this.email,
    this.deviceId,
    required this.risk,
    required this.status,
    required this.isOnline,
    required this.hasFatigueData,
    required this.alertCount,
    this.lastAlert,
    this.lastUpdated,
  });

  factory _DriverData.fromFleetDriver(FleetDriver driver) {
    final alert = driver.latestAlert;
    final risk = driver.fatigueRiskPercent ?? alert?.fatigueRiskPercent;
    final hasFatigueData = risk != null;
    return _DriverData(
      uid: driver.uid,
      displayName: _driverDisplayName(driver),
      email: driver.email,
      deviceId: driver.deviceId,
      risk: risk ?? 0,
      status: driver.fatigueStatus ?? _statusFromRiskValue(risk ?? 0),
      isOnline: driver.online,
      hasFatigueData: hasFatigueData,
      alertCount: driver.alertCount,
      lastAlert: alert?.message,
      lastUpdated: alert?.timestamp ?? driver.lastSeen,
    );
  }

  _DriverData copyWith({
    String? uid,
    String? displayName,
    String? email,
    int? risk,
    String? status,
    bool? isOnline,
    bool? hasFatigueData,
    int? alertCount,
    String? lastAlert,
    DateTime? lastUpdated,
  }) {
    return _DriverData(
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      deviceId: deviceId,
      risk: risk ?? this.risk,
      status: status ?? this.status,
      isOnline: isOnline ?? this.isOnline,
      hasFatigueData: hasFatigueData ?? this.hasFatigueData,
      alertCount: alertCount ?? this.alertCount,
      lastAlert: lastAlert ?? this.lastAlert,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }
}

String _driverDisplayName(FleetDriver driver) {
  final name = driver.displayName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final email = driver.email?.trim();
  if (email != null && email.isNotEmpty) return email;
  return driver.uid;
}

_DriverData _mergeDriverData(_DriverData previous, _DriverData next) {
  final previousTime = previous.lastUpdated;
  final nextTime = next.lastUpdated;
  final previousIsCurrent =
      previousTime != null &&
      DateTime.now().difference(previousTime).inMinutes < 5;
  final previousIsNewer =
      previousIsCurrent && (nextTime == null || previousTime.isAfter(nextTime));

  if (!previousIsNewer) {
    return next;
  }

  return next.copyWith(
    risk: previous.hasFatigueData ? previous.risk : next.risk,
    status: previous.hasFatigueData ? previous.status : next.status,
    isOnline: previousIsNewer ? previous.isOnline : next.isOnline,
    hasFatigueData: previous.hasFatigueData || next.hasFatigueData,
    alertCount: next.alertCount >= previous.alertCount
        ? next.alertCount
        : previous.alertCount,
    lastAlert: previous.lastAlert ?? next.lastAlert,
    lastUpdated: previousIsNewer ? previous.lastUpdated : next.lastUpdated,
  );
}

String _alertLevelLabel(int level) {
  switch (level) {
    case 0:
      return 'SAFE';
    case 1:
      return 'WARNING';
    case 2:
      return 'DANGER';
    default:
      return 'UNKNOWN';
  }
}

Color _alertLevelColor(int level) {
  switch (level) {
    case 0:
      return const Color(0xFF10B981);
    case 1:
      return const Color(0xFFF59E0B);
    case 2:
      return const Color(0xFFEF4444);
    default:
      return Colors.grey;
  }
}

String _statusFromRiskValue(int risk) {
  if (risk >= 90) return 'Extreme fatigue';
  if (risk >= 70) return 'Critical fatigue';
  if (risk >= 50) return 'High fatigue';
  if (risk >= 30) return 'Moderate fatigue';
  if (risk >= 10) return 'Low fatigue';
  return 'No data';
}

Color _riskColor(int risk, {required bool hasFatigueData}) {
  if (!hasFatigueData) return Colors.grey;
  if (risk >= 70) return const Color(0xFFEF4444);
  if (risk >= 40) return const Color(0xFFF59E0B);
  return const Color(0xFF10B981);
}

class _DriverCard extends StatelessWidget {
  final _DriverData driver;
  final int rank;
  final VoidCallback onViewAlerts;
  final VoidCallback onRemove;

  const _DriverCard({
    required this.driver,
    required this.rank,
    required this.onViewAlerts,
    required this.onRemove,
  });

  String _formatTime(DateTime? time) {
    if (time == null) return 'No data yet';
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(
      driver.risk,
      hasFatigueData: driver.hasFatigueData,
    );
    final deviceText = driver.deviceId == null
        ? 'No device assigned'
        : 'Device: ${driver.deviceId}';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 60,
              height: 60,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: driver.hasFatigueData ? driver.risk / 100 : 0,
                    strokeWidth: 6,
                    color: color,
                    backgroundColor: Colors.grey.shade300,
                  ),
                  Center(
                    child: Text(
                      driver.hasFatigueData ? '${driver.risk}%' : 'N/A',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: color,
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
                  Text(
                    '#$rank • ${driver.displayName}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    deviceText,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _StatusBadge(label: driver.status, color: color),
                      _StatusBadge(
                        label: driver.isOnline ? 'Live' : 'Offline',
                        color: driver.isOnline
                            ? const Color(0xFF10B981)
                            : Colors.grey,
                      ),
                      _StatusBadge(
                        label: '${driver.alertCount} alerts',
                        color: driver.alertCount > 0
                            ? const Color(0xFF3B82F6)
                            : Colors.grey,
                      ),
                    ],
                  ),
                  if (driver.lastAlert != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      driver.lastAlert!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey.shade700),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    'Last updated: ${_formatTime(driver.lastUpdated)}',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'View alerts',
              onPressed: onViewAlerts,
              icon: const Icon(Icons.history_rounded),
            ),
            IconButton(
              tooltip: 'Remove from fleet',
              onPressed: onRemove,
              icon: const Icon(
                Icons.person_remove_rounded,
                color: Color(0xFFEF4444),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final List<_DriverData> drivers;

  const _SummaryRow({required this.drivers});

  @override
  Widget build(BuildContext context) {
    final total = drivers.length;
    final critical = drivers
        .where((d) => d.hasFatigueData && d.risk >= 70)
        .length;
    final alerts = drivers.fold<int>(
      0,
      (sum, driver) => sum + driver.alertCount,
    );
    final offline = drivers.where((d) => !d.isOnline).length;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _SummaryBox('Drivers', total.toString()),
        _SummaryBox('Critical', critical.toString()),
        _SummaryBox('Alerts', alerts.toString()),
        _SummaryBox('Offline', offline.toString()),
      ],
    );
  }
}

class _SummaryBox extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryBox(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  final String state;

  const _ConnectionBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    final isConnected = state == 'Connected';
    final color = isConnected
        ? const Color(0xFF10B981)
        : const Color(0xFFF59E0B);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        state,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _FleetHeader extends StatelessWidget {
  final String fleetName;
  final String? inviteCode;

  const _FleetHeader({required this.fleetName, required this.inviteCode});

  @override
  Widget build(BuildContext context) {
    final code = inviteCode;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.local_shipping_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fleetName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (code != null && code.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Invite code: $code',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ],
              ),
            ),
            if (code != null && code.isNotEmpty)
              IconButton(
                tooltip: 'Copy invite code',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Invite code copied')),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatAlertTime(DateTime? time) {
  if (time == null) return 'No timestamp';
  final h = time.hour.toString().padLeft(2, '0');
  final m = time.minute.toString().padLeft(2, '0');
  final s = time.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

class _FleetLoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _FleetLoadError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 44),
          const SizedBox(height: 12),
          Text(
            'Could not load fleet',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.grey.shade600),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _EmptyFleetState extends StatelessWidget {
  final String? inviteCode;

  const _EmptyFleetState({required this.inviteCode});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodyMedium?.color?.withOpacity(0.72);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sensors_rounded, size: 48, color: muted),
          const SizedBox(height: 12),
          Text(
            'No assigned drivers yet',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            inviteCode == null || inviteCode!.isEmpty
                ? 'Drivers will appear here after they join your fleet.'
                : 'Drivers will appear here after they join with invite code $inviteCode.',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}
