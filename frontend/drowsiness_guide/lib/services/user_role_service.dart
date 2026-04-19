import 'dart:convert';

import 'package:http/http.dart' as http;

class UserRoleServiceException implements Exception {
  final String message;
  final int? statusCode;

  const UserRoleServiceException(this.message, {this.statusCode});

  bool get isNotFound => statusCode == 404;

  @override
  String toString() => message;
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

  Future<String?> fetchRole(String uid) async {
    final http.Response response;
    try {
      response = await http
          .get(Uri.parse('$backendBaseUrl/users/$uid'))
          .timeout(_timeout);
    } on Exception {
      throw const UserRoleServiceException('Could not reach the profile server. Check your connection.');
    }

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        'Failed to fetch user role',
        statusCode: response.statusCode,
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final role = decoded['role'];
    if (role is! String || role.isEmpty) {
      throw const UserRoleServiceException('User role response was invalid');
    }

    return role;
  }

  Future<void> saveRole({
    required String uid,
    required String role,
  }) async {
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$backendBaseUrl/users'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'uid': uid, 'role': role}),
          )
          .timeout(_timeout);
    } on Exception {
      throw const UserRoleServiceException('Could not reach the profile server. Check your connection.');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UserRoleServiceException(
        'Failed to save user role (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }
}
