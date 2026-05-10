import 'package:flutter_test/flutter_test.dart';
import 'package:drowsiness_guide/utils/fatigue_risk_logic.dart';

void main() {
  group('FatigueRiskLogic.applyAlert', () {
    test('uses reported risk when present', () {
      expect(
        FatigueRiskLogic.applyAlert(
          currentRisk: 20,
          isRecovered: false,
          reportedRiskPercent: 77,
        ),
        77,
      );
    });

    test('keeps same risk on recovered alert without reported risk', () {
      expect(
        FatigueRiskLogic.applyAlert(
          currentRisk: 40,
          isRecovered: true,
          reportedRiskPercent: null,
        ),
        40,
      );
    });

    test('increments by 5 on short active event without reported risk', () {
      expect(
        FatigueRiskLogic.applyAlert(
          currentRisk: 40,
          isRecovered: false,
          reportedRiskPercent: null,
          eventDurationSeconds: 2.9,
        ),
        45,
      );
    });

    test('uses continuous duration target after 3 seconds', () {
      expect(
        FatigueRiskLogic.applyAlert(
          currentRisk: 0,
          isRecovered: false,
          reportedRiskPercent: null,
          eventDurationSeconds: 4,
        ),
        80,
      );
    });
  });

  group('FatigueRiskLogic.applyRamp', () {
    test('does not timer-ramp before continuous threshold', () {
      expect(
        FatigueRiskLogic.applyRamp(
          currentRisk: 40,
          isActiveFatigue: true,
          activeDurationSeconds: 3,
        ),
        40,
      );
    });

    test('ramps long continuous event to 100 by 5 seconds', () {
      expect(
        FatigueRiskLogic.applyRamp(
          currentRisk: 40,
          isActiveFatigue: true,
          activeDurationSeconds: 4,
        ),
        80,
      );
      expect(
        FatigueRiskLogic.applyRamp(
          currentRisk: 80,
          isActiveFatigue: true,
          activeDurationSeconds: 5,
        ),
        100,
      );
      expect(
        FatigueRiskLogic.applyRamp(
          currentRisk: 90,
          isActiveFatigue: true,
          activeDurationSeconds: 4,
        ),
        90,
      );
    });

    test('keeps active risk unchanged without duration', () {
      expect(
        FatigueRiskLogic.applyRamp(currentRisk: 40, isActiveFatigue: true),
        40,
      );
    });

    test('recovers by 2 when inactive', () {
      expect(
        FatigueRiskLogic.applyRamp(currentRisk: 40, isActiveFatigue: false),
        38,
      );
    });

    test('clamps bounds to 0..100', () {
      expect(
        FatigueRiskLogic.applyRamp(currentRisk: 100, isActiveFatigue: true),
        100,
      );
      expect(
        FatigueRiskLogic.applyRamp(currentRisk: 0, isActiveFatigue: false),
        0,
      );
      expect(
        FatigueRiskLogic.applyAlert(
          currentRisk: 95,
          isRecovered: false,
          reportedRiskPercent: null,
        ),
        100,
      );
    });
  });

  group('FatigueRiskLogic event timing', () {
    test('infers continuous event start from event time and duration', () {
      final eventTime = DateTime(2026, 1, 1, 12);

      expect(
        FatigueRiskLogic.inferEventStartedAt(
          eventTime: eventTime,
          eventDurationSeconds: 3.5,
        ),
        eventTime.subtract(const Duration(milliseconds: 3500)),
      );
    });

    test('keeps earliest known continuous event start', () {
      final previous = DateTime(2026, 1, 1, 11, 59, 50);
      final eventTime = DateTime(2026, 1, 1, 12);

      expect(
        FatigueRiskLogic.inferEventStartedAt(
          eventTime: eventTime,
          eventDurationSeconds: 3.5,
          previousStartedAt: previous,
        ),
        previous,
      );
    });

    test('computes active duration from shared helper', () {
      expect(
        FatigueRiskLogic.activeDurationSeconds(
          startedAt: DateTime(2026, 1, 1, 12),
          now: DateTime(2026, 1, 1, 12, 0, 4, 500),
        ),
        4.5,
      );
    });
  });
}
