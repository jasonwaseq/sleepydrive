class FatigueRiskLogic {
  static const int alertStep = 10;
  static const int rampStep = 2;
  static const int recoveryStep = 2;

  static int applyAlert({
    required int currentRisk,
    required bool isRecovered,
    int? reportedRiskPercent,
  }) {
    if (reportedRiskPercent != null) {
      return _clampRisk(reportedRiskPercent);
    }
    if (isRecovered) return _clampRisk(currentRisk);
    return _clampRisk(currentRisk + alertStep);
  }

  static int applyRamp({
    required int currentRisk,
    required bool isActiveFatigue,
  }) {
    if (isActiveFatigue) {
      if (currentRisk >= 100) return 100;
      return _clampRisk(currentRisk + rampStep);
    }
    if (currentRisk <= 0) return 0;
    return _clampRisk(currentRisk - recoveryStep);
  }

  static int _clampRisk(int value) => value.clamp(0, 100).toInt();
}
