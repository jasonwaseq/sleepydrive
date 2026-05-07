import 'package:flutter_test/flutter_test.dart';
import 'package:drowsiness_guide/services/jetson_websocket_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // JetsonAlert.levelLabel
  // ---------------------------------------------------------------------------
  group('JetsonAlert.levelLabel', () {
    test('level 0 → SAFE', () {
      expect(JetsonAlert(deviceId: 'dev', level: 0, message: 'm').levelLabel, 'SAFE');
    });

    test('level 1 → WARNING', () {
      expect(JetsonAlert(deviceId: 'dev', level: 1, message: 'm').levelLabel, 'WARNING');
    });

    test('level 2 → DANGER', () {
      expect(JetsonAlert(deviceId: 'dev', level: 2, message: 'm').levelLabel, 'DANGER');
    });

    test('unknown level → UNKNOWN', () {
      expect(JetsonAlert(deviceId: 'dev', level: 99, message: 'm').levelLabel, 'UNKNOWN');
    });
  });

  // ---------------------------------------------------------------------------
  // processMessageForTesting — alert parsing
  // ---------------------------------------------------------------------------
  group('processMessageForTesting', () {
    late JetsonWebSocketService svc;
    late List<JetsonAlert> alerts;
    late List<JetsonPresence> presences;

    setUp(() {
      svc = JetsonWebSocketService(uri: Uri.parse('ws://localhost'));
      alerts = [];
      presences = [];
      svc.alerts.listen(alerts.add);
      svc.presence.listen(presences.add);
    });

    tearDown(() => svc.dispose());

    test('pipe-format "2|message" emits level-2 alert', () async {
      svc.processMessageForTesting('2|Drowsy detected');
      await Future<void>.delayed(Duration.zero);
      expect(alerts.length, 1);
      expect(alerts.first.level, 2);
      expect(alerts.first.message, 'Drowsy detected');
    });

    test('pipe-format with empty message defaults to "Alert"', () async {
      svc.processMessageForTesting('1|');
      await Future<void>.delayed(Duration.zero);
      expect(alerts.first.message, 'Alert');
    });

    test('plain text emits level-1 alert', () async {
      svc.processMessageForTesting('driver is falling asleep');
      await Future<void>.delayed(Duration.zero);
      expect(alerts.length, 1);
      expect(alerts.first.level, 1);
      expect(alerts.first.message, 'driver is falling asleep');
    });

    test('empty string emits nothing', () async {
      svc.processMessageForTesting('');
      await Future<void>.delayed(Duration.zero);
      expect(alerts, isEmpty);
      expect(presences, isEmpty);
    });

    test('JSON alert envelope parsed correctly', () async {
      svc.processMessageForTesting(
        '{"type":"alert","data":{"device_id":"jetson-1","level":2,"message":"DROWSINESS"}}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(alerts.length, 1);
      expect(alerts.first.deviceId, 'jetson-1');
      expect(alerts.first.level, 2);
      expect(alerts.first.message, 'DROWSINESS');
      expect(presences, isEmpty);
    });

    test('JSON presence envelope emits presence only, not alert', () async {
      svc.processMessageForTesting(
        '{"type":"jetson_presence","data":{"source_id":"jetson-1","online":true}}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(presences.length, 1);
      expect(presences.first.sourceId, 'jetson-1');
      expect(presences.first.online, isTrue);
      expect(alerts, isEmpty);
    });

    test('heartbeat without online field treated as online', () async {
      svc.processMessageForTesting(
        '{"type":"heartbeat","source_id":"jetson-2"}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(presences.length, 1);
      expect(presences.first.sourceId, 'jetson-2');
      expect(presences.first.online, isTrue);
    });

    test('status-type JSON emits presence', () async {
      svc.processMessageForTesting(
        '{"type":"status","source_id":"jetson-3","online":false}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(presences.length, 1);
      expect(presences.first.online, isFalse);
    });

    test('fatigue_risk_percent in JSON payload is propagated to alert', () async {
      svc.processMessageForTesting(
        '{"level":2,"message":"drowsy","fatigue_risk_percent":85}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(alerts.length, 1);
      expect(alerts.first.fatigueRiskPercent, 85);
    });

    test('fractional fatigue risk (0–1 range) is scaled to percent', () async {
      svc.processMessageForTesting(
        '{"level":2,"message":"drowsy","fatigue_risk_percent":0.75}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(alerts.first.fatigueRiskPercent, 75);
    });

    test('non-alert JSON type returns no alert', () async {
      // type "info" is not a known alert type
      svc.processMessageForTesting(
        '{"type":"info","message":"system ready"}',
      );
      await Future<void>.delayed(Duration.zero);
      expect(alerts, isEmpty);
    });
  });
}
