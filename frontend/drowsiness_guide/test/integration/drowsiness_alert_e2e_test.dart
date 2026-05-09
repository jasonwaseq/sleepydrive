import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drowsiness_guide/screens/live_monitor_screen.dart';
import 'package:drowsiness_guide/services/jetson_websocket_service.dart';
import '../helpers/mocks.dart';

void _suppressOverflowErrors() {
  final original = FlutterError.onError!;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    original(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

void main() {
  testWidgets('E2E: Drowsiness Alert appears when real WebSocket receives event', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    _suppressOverflowErrors();

    final mockAuth = MockAuthService();
    // Connects to the real local backend. The backend must be running, and the 
    // `inject_event.py` script should be executed to trigger the alert during this test.
    final wsService = JetsonWebSocketService(uri: Uri.parse('ws://localhost:8000/ws/alerts'));

    await tester.pumpWidget(
      MaterialApp(
        home: LiveMonitorScreen(
          authService: mockAuth,
          jetsonWsService: wsService,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Since this is an E2E test, we wait up to 5 seconds for the external event 
    // to be injected and processed by the backend and broadcasted to us.
    bool foundAlert = false;
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      // Look for the SnackBar or Alert Card containing the injected message
      if (find.textContaining('Drowsiness alert').evaluate().isNotEmpty ||
          find.textContaining('Drowsiness detected (Simulated)').evaluate().isNotEmpty) {
        foundAlert = true;
        break;
      }
    }

    expect(
      foundAlert, 
      isTrue, 
      reason: 'Expected alert message to appear in the UI from WebSocket. '
              'Did you run `python tests/helpers/inject_event.py`?'
    );
    
    wsService.dispose();
  });
}
