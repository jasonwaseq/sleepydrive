class FatigueRiskLogic {
  static const int alertStep = 5;
  static const double continuousThresholdSeconds = 3.0;
  static const double continuousRampToFullSeconds = 5.0;
  static const int recoveryStep = 2;

  static int applyAlert({
    required int currentRisk,
    required bool isRecovered,
    int? reportedRiskPercent,
    double? eventDurationSeconds,
  }) {
    if (reportedRiskPercent != null) {
      return _clampRisk(reportedRiskPercent);
    }
    if (isRecovered) return _clampRisk(currentRisk);
    if (_isLongContinuousEvent(eventDurationSeconds)) {
      return _maxRisk(
        currentRisk,
        _riskForContinuousDuration(eventDurationSeconds!),
      );
    }
    return _clampRisk(currentRisk + alertStep);
  }

  static int applyRamp({
    required int currentRisk,
    required bool isActiveFatigue,
    double? activeDurationSeconds,
  }) {
    if (isActiveFatigue) {
      if (!_isLongContinuousEvent(activeDurationSeconds)) {
        return _clampRisk(currentRisk);
      }
      return _maxRisk(
        currentRisk,
        _riskForContinuousDuration(activeDurationSeconds!),
      );
    }
    if (currentRisk <= 0) return 0;
    return _clampRisk(currentRisk - recoveryStep);
  }

  static DateTime inferEventStartedAt({
    required DateTime eventTime,
    double? eventDurationSeconds,
    DateTime? previousStartedAt,
  }) {
    if (eventDurationSeconds == null) return previousStartedAt ?? eventTime;
    final inferred = eventTime.subtract(
      Duration(milliseconds: (eventDurationSeconds * 1000).round()),
    );
    if (previousStartedAt == null) return inferred;
    return inferred.isBefore(previousStartedAt) ? inferred : previousStartedAt;
  }

  static double activeDurationSeconds({
    required DateTime startedAt,
    required DateTime now,
  }) {
    final milliseconds = now.difference(startedAt).inMilliseconds;
    return milliseconds <= 0 ? 0 : milliseconds / 1000.0;
  }

  static bool _isLongContinuousEvent(double? durationSeconds) {
    return durationSeconds != null &&
        durationSeconds > continuousThresholdSeconds;
  }

  static int _riskForContinuousDuration(double durationSeconds) {
    final risk = (durationSeconds / continuousRampToFullSeconds * 100).round();
    return _clampRisk(risk);
  }

  static int _maxRisk(int a, int b) => _clampRisk(a > b ? a : b);

  static int _clampRisk(int value) => value.clamp(0, 100).toInt();
}
