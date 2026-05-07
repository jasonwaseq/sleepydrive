# backend folder

Backend now contains:

1. `ble/`: BLE notifier stack for direct Bluetooth alerts.
2. `realtime/`: MQTT uplink + Postgres consumer + WebSocket gateway.

Realtime gateway: install with `pip install -r requirements.txt`, then from `backend/` run `python run_server.py` (or the same under `backend/realtime/`).

## run server/database tests

These backend tests validate payload parsing/auth behavior and DB persistence contracts.
They are mock-based integration/unit tests and do not require a running Postgres instance.

### 1) go to backend folder

```bash
cd backend
```

### 2) install dependencies

Use one of the following:

```bash
python -m pip install -r requirements.txt -r requirements-test.txt
```

or

```bash
python3 -m pip install -r requirements.txt -r requirements-test.txt
```

### 3) run all backend tests

```bash
python -m pytest
```

### 4) run only server/database-focused tests

```bash
python -m pytest tests/test_app_api.py tests/test_mqtt_consumer.py tests/test_repository.py
```

### 5) optional: quieter output

```bash
python -m pytest -q
```