import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:drowsiness_guide/screens/fleet_operator_dashboard.dart';
import 'package:drowsiness_guide/services/user_role_service.dart';
import '../helpers/mocks.dart';

void main() {
  late MockJetsonWebSocketService mockWs;
  late MockUserRoleService mockRole;
  const fleet = FleetInfo(id: 'f1', name: 'Acme Fleet', inviteCode: 'INV');

  setUp(() {
    mockWs = MockJetsonWebSocketService();
    mockRole = MockUserRoleService();
  });

  tearDown(() async {
    await mockWs.alertCtrl.close();
    await mockWs.presenceCtrl.close();
    await mockWs.stateCtrl.close();
  });

  testWidgets('shows fleet name after dashboard loads and connects Jetson',
      (tester) async {
    when(mockRole.fetchFleetDashboard()).thenAnswer(
      (_) async => FleetDashboardData(
        fleet: fleet,
        drivers: const [],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FleetOperatorDashboard(
          jetsonWsService: mockWs,
          userRoleService: mockRole,
          authService: MockAuthService(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Fleet Dashboard'), findsOneWidget);
    verify(mockWs.connect()).called(1);
    expect(find.text('Acme Fleet'), findsOneWidget);
  });

  testWidgets('disposes Jetson service when widget is removed', (tester) async {
    when(mockRole.fetchFleetDashboard()).thenAnswer(
      (_) async => FleetDashboardData(
        fleet: fleet,
        drivers: const [],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FleetOperatorDashboard(
          jetsonWsService: mockWs,
          userRoleService: mockRole,
          authService: MockAuthService(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    verify(mockWs.dispose()).called(1);
  });

}
