import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:drowsiness_guide/app.dart';
import 'package:drowsiness_guide/services/jetson_websocket_service.dart';
import 'package:drowsiness_guide/services/auth_service.dart';
import 'package:drowsiness_guide/services/user_role_service.dart';

class FleetOperatorDashboard extends StatefulWidget {
  const FleetOperatorDashboard({super.key});

  @override
  State<FleetOperatorDashboard> createState() => _FleetOperatorDashboardState();
}

class _FleetOperatorDashboardState extends State<FleetOperatorDashboard> {
  static const String _jetsonWsUrl = String.fromEnvironment(
    'JETSON_WS_URL',
    defaultValue: 'ws://localhost:8080/ws/alerts?replay=0',
  );

  late final JetsonWebSocketService _jetsonWs = JetsonWebSocketService(
    uri: Uri.parse(_jetsonWsUrl),
  );
  final UserRoleService _userRoleService = UserRoleService();

  StreamSubscription<JetsonAlert>? _alertSub;
  StreamSubscription<JetsonPresence>? _presenceSub;
  StreamSubscription<String>? _stateSub;

  String _wsState = 'Disconnected';
  String? _fleetName;
  String? _fleetInviteCode;
  String? _fleetLoadError;
  bool _isLoadingFleet = true;

  final Map<String, _DriverData> _driversByUid = {};

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
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _presenceSub?.cancel();
    _stateSub?.cancel();
    _jetsonWs.dispose();
    super.dispose();
  }

  void _handleAlert(JetsonAlert alert) {
    if (!mounted) return;

    setState(() {
      final entries = _entriesForDevice(alert.deviceId);
      if (entries.isEmpty) return;

      final updatedRisk = _riskFromLevel(alert.level);
      final updatedStatus = _statusFromRisk(updatedRisk);

      for (final entry in entries) {
        _driversByUid[entry.key] = entry.value.copyWith(
          risk: updatedRisk,
          status: updatedStatus,
          isOnline: true,
          hasFatigueData: true,
          lastAlert: alert.message,
          lastUpdated: alert.timestamp,
        );
      }
    });
  }

  void _handlePresence(JetsonPresence presence) {
    if (!mounted) return;

    setState(() {
      final entries = _entriesForDevice(presence.sourceId);
      if (entries.isEmpty) return;

      for (final entry in entries) {
        _driversByUid[entry.key] = entry.value.copyWith(
          isOnline: presence.online,
          lastUpdated: presence.timestamp,
        );
      }
    });
  }

  int _riskFromLevel(int level) {
    return _riskFromLevelValue(level);
  }

  String _statusFromRisk(int risk) {
    return _statusFromRiskValue(risk);
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

  List<MapEntry<String, _DriverData>> _entriesForDevice(String deviceId) {
    final matches = <MapEntry<String, _DriverData>>[];
    for (final entry in _driversByUid.entries) {
      if (entry.value.deviceId == deviceId) {
        matches.add(entry);
      }
    }
    return matches;
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
      if (e.statusCode == 403 && e.message.contains('operator')) {
        try {
          await _ensureOperatorProfile();
          final data = await _userRoleService.fetchFleetDashboard();
          _applyFleetDashboardData(data);
        } catch (retryError) {
          if (!mounted) return;
          setState(() {
            _fleetLoadError = retryError.toString().replaceFirst('Exception: ', '');
          });
        }
      } else {
        if (!mounted) return;
        setState(() {
          _fleetLoadError = e.toString().replaceFirst('Exception: ', '');
        });
      }
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

  Future<void> _ensureOperatorProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const UserRoleServiceException('No authenticated Firebase user');
    }

    await _userRoleService.saveRole(
      uid: user.uid,
      role: 'operator',
      email: user.email,
      displayName: user.displayName,
    );
  }

  void _applyFleetDashboardData(FleetDashboardData data) {
    if (!mounted) return;

    setState(() {
      _fleetName = data.fleet.name;
      _fleetInviteCode = data.fleet.inviteCode;
      _driversByUid
        ..clear()
        ..addEntries(
          data.drivers.map(
            (driver) => MapEntry(
              driver.uid,
              _DriverData.fromFleetDriver(driver),
            ),
          ),
        );
    });
  }

  Future<void> _backToLogin() async {
    await AuthService().signOut();

    if (!mounted) return;

    Navigator.pushNamedAndRemoveUntil(
        context,
        '/login',
        (route) => false,
    );
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
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
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
      setState(() => _driversByUid.remove(driver.uid));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${driver.displayName} removed from fleet')),
      );
    } on UserRoleServiceException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = DriverSafetyApp.of(context).isDark;
    final bgTop = isDark ? const Color(0xFF0B1220) : const Color(0xFFCED8E4);
    final bgBottom = isDark ? const Color(0xFF0E1628) : const Color(0xFF7E97B9);

    final sortedDrivers = _sortedDrivers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Fleet Dashboard'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: _ConnectionBadge(state: _wsState),
            ),
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
                                  return AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                    child: _DriverCard(
                                      driver: sortedDrivers[i],
                                      rank: i + 1,
                                      onViewAlerts: () =>
                                          _showDriverAlerts(sortedDrivers[i]),
                                      onRemove: () =>
                                          _removeDriver(sortedDrivers[i]),
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
      showDragHandle: true,
      builder: (context) {
        return FutureBuilder<List<FleetAlert>>(
          future: _userRoleService.fetchDriverAlerts(driver.uid),
          builder: (context, snapshot) {
            final alerts = snapshot.data ?? const <FleetAlert>[];

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driver.displayName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 12),
                    if (snapshot.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (snapshot.hasError)
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
                          maxHeight: MediaQuery.of(context).size.height * 0.48,
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: alerts.length,
                          separatorBuilder: (_, __) => const Divider(),
                          itemBuilder: (context, index) {
                            final alert = alerts[index];
                            final risk = _riskFromLevelValue(alert.level);
                            final color = _riskColor(
                              risk,
                              hasFatigueData: true,
                            );
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                Icons.warning_rounded,
                                color: color,
                              ),
                              title: Text(alert.message),
                              subtitle: Text(_formatAlertTime(alert.timestamp)),
                              trailing: Text(
                                '$risk%',
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
  }
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
    this.lastAlert,
    this.lastUpdated,
  });

  factory _DriverData.fromFleetDriver(FleetDriver driver) {
    final alert = driver.latestAlert;
    final risk = alert == null ? 0 : _riskFromLevelValue(alert.level);
    return _DriverData(
      uid: driver.uid,
      displayName: _driverDisplayName(driver),
      email: driver.email,
      deviceId: driver.deviceId,
      risk: risk,
      status: alert == null ? 'No data' : _statusFromRiskValue(risk),
      isOnline: driver.online,
      hasFatigueData: alert != null,
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
    String? lastAlert,
    DateTime? lastUpdated,
  }) {
    return _DriverData(
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      deviceId: this.deviceId,
      risk: risk ?? this.risk,
      status: status ?? this.status,
      isOnline: isOnline ?? this.isOnline,
      hasFatigueData: hasFatigueData ?? this.hasFatigueData,
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

int _riskFromLevelValue(int level) {
  switch (level) {
    case 0:
      return 20;
    case 1:
      return 55;
    case 2:
      return 85;
    default:
      return 30;
  }
}

String _statusFromRiskValue(int risk) {
  if (risk >= 70) return 'Critical';
  if (risk >= 40) return 'Elevated';
  return 'Normal';
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
    final deviceText =
        driver.deviceId == null ? 'No device assigned' : 'Device: ${driver.deviceId}';

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
                  Row(
                    children: [
                      _StatusBadge(
                        label: driver.status,
                        color: color,
                      ),
                      const SizedBox(width: 8),
                      _StatusBadge(
                        label: driver.isOnline ? 'Live' : 'Offline',
                        color: driver.isOnline
                            ? const Color(0xFF10B981)
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
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
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
              icon: const Icon(Icons.person_remove_rounded, color: Color(0xFFEF4444)),
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

  const _StatusBadge({
    required this.label,
    required this.color,
  });

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
    final critical = drivers.where((d) => d.hasFatigueData && d.risk >= 70).length;
    final elevated = drivers
        .where((d) => d.hasFatigueData && d.risk >= 40 && d.risk < 70)
        .length;
    final offline = drivers.where((d) => !d.isOnline).length;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _SummaryBox('Drivers', total.toString()),
        _SummaryBox('Critical', critical.toString()),
        _SummaryBox('Elevated', elevated.toString()),
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
    final color = isConnected ? const Color(0xFF10B981) : const Color(0xFFF59E0B);

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

  const _FleetHeader({
    required this.fleetName,
    required this.inviteCode,
  });

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

  const _FleetLoadError({
    required this.message,
    required this.onRetry,
  });

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
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
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
    final muted =
        Theme.of(context).textTheme.bodyMedium?.color?.withOpacity(0.72);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.sensors_rounded,
            size: 48,
            color: muted,
          ),
          const SizedBox(height: 12),
          Text(
            'No assigned drivers yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            inviteCode == null || inviteCode!.isEmpty
                ? 'Drivers will appear here after they join your fleet.'
                : 'Drivers will appear here after they join with invite code $inviteCode.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: muted,
                ),
          ),
        ],
      ),
    );
  }
}
