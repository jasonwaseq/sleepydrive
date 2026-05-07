import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drowsiness_guide/screens/login_screen.dart';
import '../helpers/mocks.dart';

void _suppressOverflowErrors() {
  final original = FlutterError.onError!;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    original(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

/// Broader smoke path without legacy auth SDK dependencies (matches injected-deps pattern used in
/// [login_screen_test.dart]).
void main() {
  testWidgets('login screen shows keyed fields with mocked auth stack',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    _suppressOverflowErrors();

    final mockAuth = MockAuthService();
    final mockRole = MockUserRoleService();

    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          authService: mockAuth,
          userRoleService: mockRole,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('login_email')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('login_password')), findsOneWidget);
  });
}
