# UNOFFICIAL REPO FOR 123. DO NOT SUBMIT OR SHARE OUTSIDE OF GROUP 7.

This repo will compile all the work done for this class and then we'll split it up accordingly after to push to the legit github "https://github.com/PJ-004/CSE123A-Group7-Project.git". 

## Jetson code

`jetson_code/` is a Git submodule that points to:

`https://github.com/jasonwaseq/Jetson-Orin-Nano-MediaPipe-Driver-Monitoring-System`

After cloning this repo, initialize it with:

`git submodule update --init --recursive`

# How to run:

`flutter run`

## Frontend Tests

To run the Flutter tests locally, you must first create a `secrets.dart` file since it requires the OpenWeather API key.

1. Create `frontend/drowsiness_guide/lib/secrets.dart`
2. Add your OpenWeather API key:
```dart
const String openWeatherApiKey = 'YOUR_API_KEY_HERE';
```
3. Run the tests:
```bash
cd frontend/drowsiness_guide
flutter test
```

## Backend tests (server/database)

From the repo root:

```bash
cd backend
python -m pip install -r requirements.txt -r requirements-test.txt
python -m pytest
```

For just server/database-focused coverage:

```bash
python -m pytest tests/test_app_api.py tests/test_mqtt_consumer.py tests/test_repository.py
```

## End-to-End Tests

We have automated end-to-end blackbox tests that test the entire alert chain (MQTT injection -> Backend/Database -> WebSocket broadcast -> Flutter UI update). 

To run the backend E2E tests:
```bash
cd backend
python -m pytest tests/test_e2e_alert_chain.py tests/test_e2e_fleet_event.py
```

To run the frontend E2E test:
```bash
cd frontend/drowsiness_guide
flutter test test/integration/drowsiness_alert_e2e_test.dart
```
*(Note: To run the frontend E2E test properly, you must have the backend running locally (`python run_server.py`) and manually trigger the helper script `backend/tests/helpers/inject_event.py` while the test is waiting for the alert.)*

## Manual User Test Protocol

For assessing safety claims and real-world latency from the perspective of the Driver and Fleet Operator, see the [Manual Test Protocol](docs/manual_test_protocol.md). This document contains step-by-step instructions for reproducing and logging drowsiness events, including version A/B comparison metrics.