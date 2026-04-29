import 'package:flutter_test/flutter_test.dart';
import 'package:drowsiness_guide/services/ble_service.dart';

void main() {
  group('BleAlert.tryParsePayload', () {
    test('parses Jetson alert packets', () {
      final alert = BleAlert.tryParsePayload('2|DROWSINESS DETECTED!\n');

      expect(alert, isNotNull);
      expect(alert!.level, 2);
      expect(alert.levelLabel, 'DANGER');
      expect(alert.message, 'DROWSINESS DETECTED!');
    });

    test('ignores heartbeat and malformed packets', () {
      expect(BleAlert.tryParsePayload('-1|ping'), isNull);
      expect(BleAlert.tryParsePayload('connected'), isNull);
      expect(BleAlert.tryParsePayload('x|bad'), isNull);
    });
  });
}
