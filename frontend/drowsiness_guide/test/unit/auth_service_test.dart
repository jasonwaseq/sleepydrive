import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:drowsiness_guide/services/auth_service.dart';

import '../helpers/fake_storage.dart';

/// Builds a minimal 3-part JWT whose payload encodes [sub], [email], and [exp].
String _makeJwt({required String sub, String? email, int expOffsetSeconds = 3600}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final payload = <String, dynamic>{'sub': sub, 'exp': now + expOffsetSeconds};
  if (email != null) payload['email'] = email;
  final encoded = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return 'header.$encoded.sig';
}

void main() {
  // ---------------------------------------------------------------------------
  // restoreSession
  // ---------------------------------------------------------------------------
  group('restoreSession', () {
    test('returns null when no token stored', () async {
      final svc = AuthService(storage: FakeSecureStorage());
      expect(await svc.restoreSession(), isNull);
    });

    test('returns AuthUser for a valid non-expired token', () async {
      final storage = FakeSecureStorage(seed: {
        'auth_token': _makeJwt(sub: 'u1', email: 'a@b.com'),
      });
      final svc = AuthService(storage: storage);
      final user = await svc.restoreSession();
      expect(user?.uid, 'u1');
      expect(user?.email, 'a@b.com');
    });

    test('deletes token and returns null for expired token', () async {
      final storage = FakeSecureStorage(seed: {
        'auth_token': _makeJwt(sub: 'u1', expOffsetSeconds: -3600),
      });
      final svc = AuthService(storage: storage);
      expect(await svc.restoreSession(), isNull);
      expect(await storage.read(key: 'auth_token'), isNull);
    });

    test('deletes token and returns null for malformed token', () async {
      final storage = FakeSecureStorage(seed: {'auth_token': 'not.a.jwt'});
      final svc = AuthService(storage: storage);
      expect(await svc.restoreSession(), isNull);
      expect(await storage.read(key: 'auth_token'), isNull);
    });

    test('emits AuthUser on authStateChanges when valid', () async {
      final storage = FakeSecureStorage(seed: {
        'auth_token': _makeJwt(sub: 'u2', email: 'b@c.com'),
      });
      final svc = AuthService(storage: storage);
      final events = <AuthUser?>[];
      final sub = svc.authStateChanges.listen(events.add);
      await svc.restoreSession();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events.length, 1);
      expect(events.first?.uid, 'u2');
    });

    test('emits null on authStateChanges when no token', () async {
      final svc = AuthService(storage: FakeSecureStorage());
      final events = <AuthUser?>[];
      final sub = svc.authStateChanges.listen(events.add);
      await svc.restoreSession();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, [null]);
    });
  });

  // ---------------------------------------------------------------------------
  // getToken
  // ---------------------------------------------------------------------------
  group('getToken', () {
    test('returns null when nothing stored', () async {
      final svc = AuthService(storage: FakeSecureStorage());
      expect(await svc.getToken(), isNull);
    });

    test('returns the stored token string', () async {
      final svc = AuthService(storage: FakeSecureStorage(seed: {'auth_token': 'tok123'}));
      expect(await svc.getToken(), 'tok123');
    });
  });

  // ---------------------------------------------------------------------------
  // signInWithEmailPassword
  // ---------------------------------------------------------------------------
  group('signInWithEmailPassword', () {
    test('returns AuthUser and stores token on 200', () async {
      final storage = FakeSecureStorage();
      final token = _makeJwt(sub: 'u3', email: 'x@y.com');
      final client = MockClient((req) async {
        expect(req.url.path, '/auth/login');
        return http.Response(
          jsonEncode({'token': token, 'uid': 'u3', 'email': 'x@y.com'}),
          200,
        );
      });
      final svc = AuthService(httpClient: client, storage: storage);
      final user = await svc.signInWithEmailPassword(email: 'x@y.com', password: 'pw');
      expect(user.uid, 'u3');
      expect(user.email, 'x@y.com');
      expect(await storage.read(key: 'auth_token'), token);
    });

    test('throws on non-200 response', () async {
      final client = MockClient(
          (req) async => http.Response('{"detail":"bad credentials"}', 401));
      final svc = AuthService(httpClient: client, storage: FakeSecureStorage());
      expect(
        () => svc.signInWithEmailPassword(email: 'a@b.com', password: 'bad'),
        throwsException,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // createUserWithEmailPassword
  // ---------------------------------------------------------------------------
  group('createUserWithEmailPassword', () {
    test('returns AuthUser on 201', () async {
      final token = _makeJwt(sub: 'u4', email: 'n@o.com');
      final client = MockClient((req) async => http.Response(
            jsonEncode({'token': token, 'uid': 'u4', 'email': 'n@o.com'}),
            201,
          ));
      final svc = AuthService(httpClient: client, storage: FakeSecureStorage());
      final user = await svc.createUserWithEmailPassword(
          email: 'n@o.com', password: 'pw');
      expect(user.uid, 'u4');
      expect(user.email, 'n@o.com');
    });

    test('throws with backend message when all signup paths return 404', () async {
      final client = MockClient((req) async => http.Response('not found', 404));
      final svc = AuthService(httpClient: client, storage: FakeSecureStorage());
      await expectLater(
        () => svc.createUserWithEmailPassword(email: 'a@b.com', password: 'p'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('not found on the backend'),
        )),
      );
    });

    test('throws immediately on non-200/201/404 response', () async {
      final client = MockClient(
          (req) async => http.Response('server error', 500));
      final svc = AuthService(httpClient: client, storage: FakeSecureStorage());
      expect(
        () => svc.createUserWithEmailPassword(email: 'a@b.com', password: 'p'),
        throwsException,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // signOut
  // ---------------------------------------------------------------------------
  group('signOut', () {
    test('clears stored token and currentUser', () async {
      final token = _makeJwt(sub: 'u5');
      final storage = FakeSecureStorage(seed: {'auth_token': token});
      final svc = AuthService(storage: storage);
      await svc.restoreSession();
      expect(svc.currentUser, isNotNull);

      await svc.signOut();
      expect(svc.currentUser, isNull);
      expect(await storage.read(key: 'auth_token'), isNull);
    });

    test('emits null on authStateChanges', () async {
      final token = _makeJwt(sub: 'u5');
      final storage = FakeSecureStorage(seed: {'auth_token': token});
      final svc = AuthService(storage: storage);
      await svc.restoreSession();

      final events = <AuthUser?>[];
      final sub = svc.authStateChanges.listen(events.add);
      await svc.signOut();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events.last, isNull);
    });
  });
}
