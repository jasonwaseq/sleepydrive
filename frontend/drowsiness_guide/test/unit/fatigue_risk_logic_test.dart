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

    test('increments by step on active alert without reported risk', () {
      expect(
        FatigueRiskLogic.applyAlert(
          currentRisk: 40,
          isRecovered: false,
          reportedRiskPercent: null,
        ),
        50,
      );
    });
  });

  group('FatigueRiskLogic.applyRamp', () {
    test('ramps up by 2 while active', () {
      expect(
        FatigueRiskLogic.applyRamp(currentRisk: 40, isActiveFatigue: true),
        42,
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
}
