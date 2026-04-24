import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class UserRoleServiceException implements Exception {
  final String message;
  final int? statusCode;

  const UserRoleServiceException(this.message, {this.statusCode});

  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;
}

class UserProfile {
  final String uid;
  final String role;
  final String? email;
  final String? displayName;
  final String? fleetId;
  final String? fleetName;
  final String? fleetInviteCode;
  final String? deviceId;

  const UserProfile({
    required this.uid,
    required this.role,
    this.email,
    this.displayName,
    this.fleetId,
    this.fleetName,
    this.fleetInviteCode,
    this.deviceId,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      uid: json['uid']?.toString() ?? '',
      role: json['role']?.toString() ?? '',
      email: json['email']?.toString(),
      displayName: json['display_name']?.toString(),
      fleetId: json['fleet_id']?.toString(),
      fleetName: json['fleet_name']?.toString(),
      fleetInviteCode: json['fleet_invite_code']?.toString(),
      deviceId: json['device_id']?.toString(),
    );
  }
}

class FleetInfo {
  final String id;
  final String name;
  final String inviteCode;

  const FleetInfo({
    required this.id,
    required this.name,
    required this.inviteCode,
  });

  factory FleetInfo.fromJson(Map<String, dynamic> json) {
    return FleetInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Fleet',
      inviteCode: json['invite_code']?.toString() ?? '',
    );
  }
}

class FleetAlert {
  final int level;
  final String message;
  final DateTime? timestamp;

  const FleetAlert({
    required this.level,
    required this.message,
    this.timestamp,
  });

  factory FleetAlert.fromJson(Map<String, dynamic> json) {
    return FleetAlert(
      level: int.tryParse(json['level']?.toString() ?? '') ?? 0,
      message: json['message']?.toString() ?? 'Alert',
      timestamp: DateTime.tryParse(
        json['event_ts']?.toString() ?? json['received_ts']?.toString() ?? '',
      )?.toLocal(),
    );
  }
}

class FleetDriver {
  final String uid;
  final String? email;
  final String? displayName;
  final String? deviceId;
  final bool online;
  final DateTime? lastSeen;
  final FleetAlert? latestAlert;

  const FleetDriver({
    required this.uid,
    this.email,
    this.displayName,
    this.deviceId,
    required this.online,
    this.lastSeen,
    this.latestAlert,
  });

  factory FleetDriver.fromJson(Map<String, dynamic> json) {
    final alert = json['latest_alert'];
    return FleetDriver(
      uid: json['uid']?.toString() ?? '',
      email: json['email']?.toString(),
      displayName: json['display_name']?.toString(),
      deviceId: json['device_id']?.toString(),
      online: json['online'] == true,
      lastSeen: DateTime.tryParse(json['last_seen']?.toString() ?? '')?.toLocal(),
      latestAlert: alert is Map<String, dynamic>
          ? FleetAlert.fromJson(alert)
          : alert is Map
              ? FleetAlert.fromJson(Map<String, dynamic>.from(alert))
              : null,
    );
  }
}

class FleetDashboardData {
  final FleetInfo fleet;
  final List<FleetDriver> drivers;

  const FleetDashboardData({
    required this.fleet,
    required this.drivers,
  });

  factory FleetDashboardData.fromJson(Map<String, dynamic> json) {
    final fleetRaw = json['fleet'];
    final driversRaw = json['drivers'];
    return FleetDashboardData(
      fleet: FleetInfo.fromJson(
        fleetRaw is Map<String, dynamic>
            ? fleetRaw
            : fleetRaw is Map
                ? Map<String, dynamic>.from(fleetRaw)
                : const <String, dynamic>{},
      ),
      drivers: driversRaw is List
          ? driversRaw
              .whereType<Map>()
              .map((raw) => FleetDriver.fromJson(Map<String, dynamic>.from(raw)))
              .toList()
          : const [],
    );
  }
}

class UserRoleService {
  static const String _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://sleepydrive.onrender.com',
  );

  String get backendBaseUrl => _backendBaseUrl.endsWith('/')
      ? _backendBaseUrl.substring(0, _backendBaseUrl.length - 1)
      : _backendBaseUrl;

  static const _timeout = Duration(seconds: 20);

  Future<Map<String, String>> _headers({bool json = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    final token = await user?.getIdToken();
    if (token == null || token.isEmpty) {
      throw const UserRoleServiceException('No authenticated Firebase user');
    }

    return {
      if (json) 'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Map<String, dynamic> _decodeObject(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw const UserRoleServiceException('Profile response was invalid');
  }

  String _errorDetail(http.Response response, String fallback) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {
      // Fall through to the generic message.
    }
    return fallback;
  }

  Future<UserProfile?> fetchProfile(String uid) async {
    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse('$backendBaseUrl/users/$uid'),
            headers: await _headers(),
          )
          .timeout(_timeout);
    } on UserRoleServiceException {
      rethrow;
    } on Exception {
      throw const UserRoleServiceException(
        'Could not reach the profile server. Check your connection.',
      );
    }

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        _errorDetail(response, 'Failed to fetch user profile'),
        statusCode: response.statusCode,
      );
    }

    return UserProfile.fromJson(_decodeObject(response));
  }

  Future<String?> fetchRole(String uid) async {
    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse('$backendBaseUrl/users/$uid'),
            headers: await _headers(),
          )
          .timeout(_timeout);
    } on UserRoleServiceException {
      rethrow;
    } on Exception {
      throw const UserRoleServiceException(
        'Could not reach the profile server. Check your connection.',
      );
    }

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        _errorDetail(response, 'Failed to fetch user role'),
        statusCode: response.statusCode,
      );
    }

    final profile = UserProfile.fromJson(_decodeObject(response));
    if (profile.role.isEmpty) {
      throw const UserRoleServiceException('User role response was invalid');
    }

    return profile.role;
  }

  Future<UserProfile> saveRole({
    required String uid,
    required String role,
    String? email,
    String? displayName,
    String? fleetInviteCode,
    String? deviceId,
  }) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$backendBaseUrl/users'),
            headers: await _headers(json: true),
            body: jsonEncode({
              'uid': uid,
              'role': role,
              if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
              if (displayName != null && displayName.trim().isNotEmpty)
                'display_name': displayName.trim(),
              if (fleetInviteCode != null && fleetInviteCode.trim().isNotEmpty)
                'fleet_invite_code': fleetInviteCode.trim(),
              if (deviceId != null && deviceId.trim().isNotEmpty)
                'device_id': deviceId.trim(),
            }),
          )
          .timeout(_timeout);
    } on UserRoleServiceException {
      rethrow;
    } on Exception {
      throw const UserRoleServiceException(
        'Could not reach the profile server. Check your connection.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        _errorDetail(response, 'Failed to save user role (${response.statusCode})'),
        statusCode: response.statusCode,
      );
    }

    return UserProfile.fromJson(_decodeObject(response));
  }

  Future<FleetDashboardData> fetchFleetDashboard() async {
    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse('$backendBaseUrl/fleet/drivers'),
            headers: await _headers(),
          )
          .timeout(_timeout);
    } on UserRoleServiceException {
      rethrow;
    } on Exception {
      throw const UserRoleServiceException(
        'Could not reach the fleet server. Check your connection.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 404) {
        throw const UserRoleServiceException(
          'Fleet invite support is not deployed on the backend yet. Redeploy the backend, then refresh.',
          statusCode: 404,
        );
      }
      throw UserRoleServiceException(
        _errorDetail(response, 'Failed to load fleet drivers'),
        statusCode: response.statusCode,
      );
    }

    return FleetDashboardData.fromJson(_decodeObject(response));
  }

  Future<List<FleetAlert>> fetchDriverAlerts(String driverUid) async {
    final http.Response response;
    try {
      response = await http
          .get(
            Uri.parse('$backendBaseUrl/fleet/drivers/$driverUid/alerts'),
            headers: await _headers(),
          )
          .timeout(_timeout);
    } on UserRoleServiceException {
      rethrow;
    } on Exception {
      throw const UserRoleServiceException(
        'Could not reach the fleet server. Check your connection.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        _errorDetail(response, 'Failed to load driver alerts'),
        statusCode: response.statusCode,
      );
    }

    final decoded = _decodeObject(response);
    final items = decoded['items'];
    if (items is! List) {
      return const [];
    }
    return items
        .whereType<Map>()
        .map((raw) => FleetAlert.fromJson(Map<String, dynamic>.from(raw)))
        .toList();
  }

  Future<void> removeDriver(String driverUid) async {
    final http.Response response;
    try {
      response = await http
          .delete(
            Uri.parse('$backendBaseUrl/fleet/drivers/$driverUid'),
            headers: await _headers(),
          )
          .timeout(_timeout);
    } on UserRoleServiceException {
      rethrow;
    } on Exception {
      throw const UserRoleServiceException(
        'Could not reach the fleet server. Check your connection.',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        _errorDetail(response, 'Failed to remove driver'),
        statusCode: response.statusCode,
      );
    }
  }
}
