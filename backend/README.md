# backend folder

Backend now contains:

1. `ble/`: BLE notifier stack for direct Bluetooth alerts.
2. `realtime/`: MQTT uplink + Postgres consumer + WebSocket gateway.

Realtime gateway: install with `pip install -r requirements.txt`, then from `backend/` run `python run_server.py` (or the same under `backend/realtime/`).

## how to run tests
- `pip install -r requirements.txt -r requirements-test.txt` 
or 
- `pip3 install -r requirements.txt -r requirements-test.txt`

then

- `pytest` 
or 
- `python3 -m pytest`