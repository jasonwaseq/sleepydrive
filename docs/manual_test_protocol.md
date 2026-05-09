# SleepyDrive Manual Test Protocol

This document outlines the black-box user test scripts for verifying the drowsiness detection alerting system from the perspective of both our primary user personas: the Driver and the Fleet Operator. These tests evaluate the end-to-end performance and latency of our core safety claims.

---

## 1. Driver View Protocol

**Goal:** Verify that a drowsy driver receives a timely, unmistakable alert on their mobile device when fatigue is detected.

### Prerequisites
1. Ensure the local backend is running (`python run_server.py` in `backend/`).
2. Have the Flutter app running on an iOS/Android simulator or physical device, logged in as a **Driver**.
3. Have the local MediaPipe webcam script (`jetson_code`) running on your Mac.

### Execution Steps
1. **Baseline**: Sit in front of the webcam with eyes open. Confirm the Flutter app shows "Online" and "No fatigue" or low risk.
2. **Trigger**: Close your eyes and keep them closed for **3 consecutive seconds**.
3. **Observe**: Wait for the Flutter application to receive the alert.
4. **Action**: Open your eyes after the alert is received.

### Acceptance Criteria
- [ ] **Visual Alert**: The app displays a high-priority "Drowsiness Detected" warning.
- [ ] **Audio/Vibration Alert**: The mobile device plays an audible alarm/vibration.
- [ ] **Latency Limit**: The alert appears on the phone **within 2 seconds** of the 3-second eye-closure mark.

**Results Recording:**
- **Pass/Fail**: _________
- **Measured Latency**: _________ seconds
- **False Positives Observed**: _________ (count)

---

## 2. Fleet Operator View Protocol

**Goal:** Verify that a fleet operations manager receives reliable and timely dashboard updates when a vehicle in their fleet experiences a severe fatigue event.

### Prerequisites
1. Ensure the local backend and MQTT broker are running.
2. Have the Flutter app (or Web build) open and logged in as a **Fleet Operator**.
3. Ensure you have the `inject_event.py` helper script ready.

### Execution Steps
1. **Baseline**: Open the Fleet Dashboard and verify the "test-device" (or whichever test vehicle) is listed.
2. **Trigger**: Run the fake MQTT injector to simulate an edge device detecting severe drowsiness:
   ```bash
   python backend/tests/helpers/inject_event.py --device "test-device" --level 2 --message "Drowsiness detected (Simulated)" --risk 95
   ```
3. **Observe**: Watch the Fleet Dashboard for the vehicle's risk card to update.

### Acceptance Criteria
- [ ] **Dashboard Update**: The specific vehicle card updates to show "Critical/Extreme fatigue" and the exact alert message.
- [ ] **Latency Limit**: The fleet dashboard reflects the risk event **within 5 seconds** of the injection script completing.

**Results Recording:**
- **Pass/Fail**: _________
- **Measured Latency**: _________ seconds

---

## 3. Version Comparison Testing (A/B Testing)

To compare different thresholds or models (e.g., Version A vs Version B of the EAR algorithm):
1. Configure the Jetson/MediaPipe pipeline to **Version A** (Threshold X). Run the Driver Protocol 5 times. Record average latency and any false positives.
2. Switch configuration to **Version B** (Threshold Y). Run the Driver Protocol 5 times. Record average latency and false positives.
3. Compare the metrics to determine which algorithm version offers the best balance of fast response times versus acceptable false-positive rates.
