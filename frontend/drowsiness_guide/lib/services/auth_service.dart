import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class AuthUser {
  final String uid;
  final String? email;

  const AuthUser({required this.uid, this.email});
}

class AuthService {
  static const _tokenKey = 'auth_token';
  static const _signupPaths = <String>[
    '/auth/signup',
    '/auth/register',
    '/signup',
    '/register',
  ];
  static const _backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'https://sleepydrive.onrender.com',
  );
  static const _timeout = Duration(seconds: 20);

  final FlutterSecureStorage _storage;
  final http.Client _client;

  AuthService({http.Client? httpClient, FlutterSecureStorage? storage})
      : _client = httpClient ?? http.Client(),
        _storage = storage ?? const FlutterSecureStorage();

  AuthUser? _currentUser;
  final _authStateController = StreamController<AuthUser?>.broadcast();

  AuthUser? get currentUser => _currentUser;

  Stream<AuthUser?> get authStateChanges => _authStateController.stream;

  Future<AuthUser?> restoreSession() async {
    final token = await _storage.read(key: _tokenKey);
    if (token == null) {
      _authStateController.add(null);
      return null;
    }

    try {
      final parts = token.split('.');
      if (parts.length != 3) throw const FormatException('bad token');
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;

      final exp = payload['exp'];
      if (exp is int &&
          DateTime.fromMillisecondsSinceEpoch(exp * 1000)
              .isBefore(DateTime.now())) {
        await _storage.delete(key: _tokenKey);
        _authStateController.add(null);
        return null;
      }

      _currentUser = AuthUser(
        uid: payload['sub'] as String,
        email: payload['email'] as String?,
      );
      _authStateController.add(_currentUser);
      return _currentUser;
    } catch (_) {
      await _storage.delete(key: _tokenKey);
      _authStateController.add(null);
      return null;
    }
  }

  Future<String?> getToken() => _storage.read(key: _tokenKey);

  Future<AuthUser> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final response = await _client
        .post(
          Uri.parse('$_backendBaseUrl/auth/login'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception(_errorDetail(response));
    }

    return _storeAndReturn(response);
  }

  Future<AuthUser> createUserWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final body = jsonEncode({'email': email, 'password': password});
    http.Response? last404;

    for (final path in _signupPaths) {
      final response = await _client
          .post(
            Uri.parse('$_backendBaseUrl$path'),
            headers: const {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_timeout);

      if (response.statusCode == 404) {
        last404 = response;
        continue;
      }

      if (response.statusCode == 200 || response.statusCode == 201) {
        return _storeAndReturn(response);
      }

      throw Exception(_errorDetail(response));
    }

    if (last404 != null) {
      throw Exception(
        'Account creation endpoint was not found on the backend. '
        'Please redeploy or update the Render backend.',
      );
    }

    throw Exception('Authentication failed');
  }

  Future<void> signOut() async {
    await _storage.delete(key: _tokenKey);
    _currentUser = null;
    _authStateController.add(null);
  }

  void dispose() => _authStateController.close();

  Future<AuthUser> _storeAndReturn(http.Response response) async {
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    await _storage.write(key: _tokenKey, value: data['token'] as String);
    _currentUser = AuthUser(
      uid: data['uid'] as String,
      email: data['email'] as String?,
    );
    _authStateController.add(_currentUser);
    return _currentUser!;
  }

  String _errorDetail(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {}
    return 'Authentication failed';
  }
}
