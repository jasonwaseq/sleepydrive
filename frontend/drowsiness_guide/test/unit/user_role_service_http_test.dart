import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drowsiness_guide/services/user_role_service.dart';

import '../helpers/fake_storage.dart';

UserRoleService _svc(MockClient client) => UserRoleService(
      httpClient: client,
      storage: FakeSecureStorage(seed: {'auth_token': 'test-tok'}),
    );

void main() {
  // ---------------------------------------------------------------------------
  // fetchProfile
  // ---------------------------------------------------------------------------
  group('fetchProfile', () {
    test('returns UserProfile on 200', () async {
      final client = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer test-tok');
        return http.Response(
          jsonEncode({'uid': 'u1', 'role': 'driver', 'email': 'a@b.com'}),
          200,
        );
      });
      final profile = await _svc(client).fetchProfile('u1');
      expect(profile?.uid, 'u1');
      expect(profile?.role, 'driver');
      expect(profile?.email, 'a@b.com');
    });

    test('returns null on 404', () async {
      final client = MockClient((req) async => http.Response('', 404));
      expect(await _svc(client).fetchProfile('u1'), isNull);
    });

    test('throws UserRoleServiceException on server error', () async {
      final client = MockClient((req) async => http.Response('', 500));
      expect(
        () => _svc(client).fetchProfile('u1'),
        throwsA(isA<UserRoleServiceException>()),
      );
    });

    test('throws when not authenticated', () async {
      final client = MockClient((req) async => http.Response('', 200));
      final svc = UserRoleService(
          httpClient: client, storage: FakeSecureStorage());
      expect(
        () => svc.fetchProfile('u1'),
        throwsA(isA<UserRoleServiceException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fetchRole
  // ---------------------------------------------------------------------------
  group('fetchRole', () {
    test('returns role string on 200', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({'uid': 'u1', 'role': 'manager'}),
            200,
          ));
      expect(await _svc(client).fetchRole('u1'), 'manager');
    });

    test('returns null on 404', () async {
      final client = MockClient((req) async => http.Response('', 404));
      expect(await _svc(client).fetchRole('u1'), isNull);
    });

    test('throws on error status', () async {
      final client = MockClient((req) async => http.Response('', 503));
      expect(
        () => _svc(client).fetchRole('u1'),
        throwsA(isA<UserRoleServiceException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // saveRole
  // ---------------------------------------------------------------------------
  group('saveRole', () {
    test('returns saved UserProfile on 200', () async {
      final client = MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        expect(body['uid'], 'u1');
        expect(body['role'], 'driver');
        return http.Response(
          jsonEncode({'uid': 'u1', 'role': 'driver', 'email': 'a@b.com'}),
          200,
        );
      });
      final profile =
          await _svc(client).saveRole(uid: 'u1', role: 'driver', email: 'a@b.com');
      expect(profile.uid, 'u1');
      expect(profile.role, 'driver');
    });

    test('throws on 400 error', () async {
      final client = MockClient((req) async => http.Response('', 400));
      expect(
        () => _svc(client).saveRole(uid: 'u1', role: 'driver'),
        throwsA(isA<UserRoleServiceException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fetchFleetDashboard
  // ---------------------------------------------------------------------------
  group('fetchFleetDashboard', () {
    test('parses fleet and driver list', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'fleet': {'id': 'f1', 'name': 'Fleet A', 'invite_code': 'abc'},
              'drivers': [
                {'uid': 'd1', 'online': true},
                {'uid': 'd2', 'online': false},
              ],
            }),
            200,
          ));
      final data = await _svc(client).fetchFleetDashboard();
      expect(data.fleet.id, 'f1');
      expect(data.fleet.name, 'Fleet A');
      expect(data.drivers.length, 2);
      expect(data.drivers.first.uid, 'd1');
      expect(data.drivers.first.online, isTrue);
    });

    test('throws UserRoleServiceException with isNotFound on 404', () async {
      final client = MockClient((req) async => http.Response('', 404));
      expect(
        () => _svc(client).fetchFleetDashboard(),
        throwsA(isA<UserRoleServiceException>()
            .having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // fetchDriverAlerts
  // ---------------------------------------------------------------------------
  group('fetchDriverAlerts', () {
    test('returns list of FleetAlerts', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'items': [
                {'level': 2, 'message': 'drowsy', 'event_ts': '2024-01-01T00:00:00Z'},
                {'level': 1, 'message': 'warning'},
              ],
            }),
            200,
          ));
      final alerts = await _svc(client).fetchDriverAlerts('d1');
      expect(alerts.length, 2);
      expect(alerts.first.level, 2);
      expect(alerts.first.message, 'drowsy');
    });

    test('returns empty list when items key is absent', () async {
      final client = MockClient((req) async => http.Response(jsonEncode({}), 200));
      final alerts = await _svc(client).fetchDriverAlerts('d1');
      expect(alerts, isEmpty);
    });

    test('throws on server error', () async {
      final client = MockClient((req) async => http.Response('', 500));
      expect(
        () => _svc(client).fetchDriverAlerts('d1'),
        throwsA(isA<UserRoleServiceException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // removeDriver
  // ---------------------------------------------------------------------------
  group('removeDriver', () {
    test('completes on 200 with DELETE request', () async {
      final client = MockClient((req) async {
        expect(req.method, 'DELETE');
        expect(req.url.path, contains('d1'));
        return http.Response('', 200);
      });
      await expectLater(_svc(client).removeDriver('d1'), completes);
    });

    test('throws on 403', () async {
      final client = MockClient((req) async => http.Response('', 403));
      expect(
        () => _svc(client).removeDriver('d1'),
        throwsA(isA<UserRoleServiceException>()),
      );
    });
  });
}
