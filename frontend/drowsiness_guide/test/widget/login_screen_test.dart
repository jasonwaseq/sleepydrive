import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:drowsiness_guide/screens/login_screen.dart';
import '../helpers/mocks.dart';

// Google Fonts can't fetch from network in tests, so it falls back to a system
// font with different metrics, causing the Google Sign-In button Row to report
// an overflow warning. This suppresses that layout warning in tests without
// masking other real errors.
void _suppressOverflowErrors() {
  final original = FlutterError.onError!;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    original(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

// Specific credentials reused across tests — stubs match exactly what's typed.
const _email = 'user@example.com';
const _pass = 'password123';
const _uid = 'test-uid-123'; // matches FakeUser.uid

Widget _buildApp(Widget screen) {
  return MaterialApp(
    home: screen,
    routes: {
      '/dashboard': (_) => const Scaffold(body: Text('Dashboard')),
      '/fleet-dashboard': (_) => const Scaffold(body: Text('Fleet Dashboard')),
      '/select-role': (_) => const Scaffold(body: Text('Select Role')),
    },
  );
}

void main() {
  late MockAuthService mockAuth;
  late MockUserRoleService mockRoleService;

  setUp(() {
    mockAuth = MockAuthService();
    mockRoleService = MockUserRoleService();
  });

  Widget buildScreen() => _buildApp(
        LoginScreen(authService: mockAuth, userRoleService: mockRoleService),
      );

  group('LoginScreen — initial UI', () {
    testWidgets('renders email field, password field, and Log in button',
        (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('Log in'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
    });

    testWidgets('shows no error text on first render', (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      expect(find.textContaining('Please enter'), findsNothing);
    });
  });

  group('LoginScreen — validation', () {
    testWidgets('empty fields shows missing-credentials error', (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.tap(find.text('Log in'));
      await tester.pump();
      expect(
          find.text('Please enter both email and password'), findsOneWidget);
    });

    testWidgets('only email filled still shows error', (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      expect(
          find.text('Please enter both email and password'), findsOneWidget);
    });

    testWidgets('short password in create mode shows length error',
        (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.tap(find.text('Create account'));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, '123');
      await tester.tap(find.text('Create account'));
      await tester.pump();

      expect(
          find.text('Password must be at least 6 characters'), findsOneWidget);
    });
  });

  group('LoginScreen — mode toggle', () {
    testWidgets('tapping Create account switches to create mode',
        (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      expect(find.text('Log in'), findsOneWidget);

      await tester.tap(find.text('Create account'));
      await tester.pump();

      expect(find.text('Already have an account? Log in'), findsOneWidget);
      expect(find.text('Log in'), findsNothing);
    });

    testWidgets('toggling back restores Log in button', (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.tap(find.text('Create account'));
      await tester.pump();
      await tester.tap(find.text('Already have an account? Log in'));
      await tester.pump();

      expect(find.text('Log in'), findsOneWidget);
      expect(find.text('Create account'), findsOneWidget);
    });

    testWidgets('toggling clears any existing error text', (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.tap(find.text('Log in'));
      await tester.pump();
      expect(find.text('Please enter both email and password'), findsOneWidget);

      await tester.tap(find.text('Create account'));
      await tester.pump();
      expect(find.text('Please enter both email and password'), findsNothing);
    });
  });

  group('LoginScreen — successful sign-in routing', () {
    testWidgets('driver role navigates to /dashboard', (tester) async {
      when(mockAuth.signInWithEmailPassword(email: _email, password: _pass))
          .thenAnswer((_) async => fakeAuthUser(email: _email));
      when(mockAuth.currentUser).thenReturn(fakeAuthUser(email: _email));
      when(mockRoleService.fetchRole(_uid)).thenAnswer((_) async => 'driver');

      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Dashboard'), findsOneWidget);
    });

    testWidgets('operator role navigates to /fleet-dashboard', (tester) async {
      when(mockAuth.signInWithEmailPassword(email: _email, password: _pass))
          .thenAnswer((_) async => fakeAuthUser(email: _email));
      when(mockAuth.currentUser).thenReturn(fakeAuthUser(email: _email));
      when(mockRoleService.fetchRole(_uid)).thenAnswer((_) async => 'operator');

      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Fleet Dashboard'), findsOneWidget);
    });

    testWidgets('null role navigates to /select-role', (tester) async {
      when(mockAuth.signInWithEmailPassword(email: _email, password: _pass))
          .thenAnswer((_) async => fakeAuthUser(email: _email));
      when(mockAuth.currentUser).thenReturn(fakeAuthUser(email: _email));
      when(mockRoleService.fetchRole(_uid)).thenAnswer((_) async => null);

      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Select Role'), findsOneWidget);
    });

    testWidgets('create mode navigates to /select-role without calling auth',
        (tester) async {
      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.tap(find.text('Create account'));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Create account'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Select Role'), findsOneWidget);
      verifyNever(mockAuth.signInWithEmailPassword(
          email: _email, password: _pass));
    });
  });

  group('LoginScreen — error handling', () {
    testWidgets('wrong-password error shows friendly message', (tester) async {
      when(mockAuth.signInWithEmailPassword(email: _email, password: _pass))
          .thenThrow(Exception('[auth/wrong-password] Wrong password'));

      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Invalid email or password'), findsOneWidget);
    });

    testWidgets('invalid-credential error shows friendly message',
        (tester) async {
      when(mockAuth.signInWithEmailPassword(email: _email, password: _pass))
          .thenThrow(Exception('[auth/invalid-credential]'));

      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Invalid email or password'), findsOneWidget);
    });

    testWidgets('network error shows connectivity message', (tester) async {
      when(mockAuth.signInWithEmailPassword(email: _email, password: _pass))
          .thenThrow(Exception('[auth/network-request-failed] Network error'));

      _suppressOverflowErrors();
      await tester.pumpWidget(buildScreen());
      await tester.enterText(find.byType(TextField).first, _email);
      await tester.enterText(find.byType(TextField).last, _pass);
      await tester.tap(find.text('Log in'));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Network error. Check your connection and try again.'),
        findsOneWidget,
      );
    });

  });
}
