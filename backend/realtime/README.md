# SleepyDrive Realtime Backend

This service implements:

1. MQTT uplink ingest (`sleepydrive/alerts/+`)
2. Event consumer (normalize + validate payloads)
3. Postgres persistence (`alert_events`)
4. WebSocket downlink gateway (`/ws/alerts`)
5. Jetson presence tracking (`jetson_presence` websocket frames)

## Architecture

```text
Jetson -> MQTT broker -> realtime consumer -> Postgres
                                       -> WebSocket clients
```

## Event contract

Preferred MQTT payload is JSON:

```json
{
  "device_id": "jetson-01",
  "level": 2,
  "message": "Eyes closed > 2s",
  "source": "jetson",
  "event_ts": "2026-03-04T18:10:00Z"
}
```

Legacy payload is also accepted:

```text
2|Eyes closed > 2s
```

Topic format:

```text
sleepydrive/alerts/<device_id>
```

Presence/status topic format:

```text
sleepydrive/status/<device_id>
```

## Environment variable naming

The realtime backend supports both naming styles:

1. `MQTT_HOST`, `MQTT_PORT`, `MQTT_TOPICS`, `MQTT_USERNAME`, `MQTT_PASSWORD`
2. `MP_QTT_HOST`, `MP_QTT_PORT`, `MP_QTT_TOPIC`, `MP_QTT_USERNAME`, `MP_QTT_PASSWORD`

This lets Jetson and backend use the same env set during migration.

## Quick start (Docker)

From `backend/realtime`:

```bash
docker compose up --build
```

Endpoints:

1. HTTP health: `http://localhost:8080/healthz`
2. Recent events: `http://localhost:8080/alerts/recent?limit=25`
3. WebSocket stream: `ws://localhost:8080/ws/alerts`

## Cloud broker configuration

Set these before `docker compose up --build realtime`:

```bash
set MP_QTT_HOST=broker.example.com
set MP_QTT_PORT=8883
set MP_QTT_TOPIC=sleepydrive/alerts/+
set MP_QTT_STATUS_TOPIC=sleepydrive/status/+
set MP_QTT_USERNAME=your_user
set MP_QTT_PASSWORD=your_password
set MP_QTT_TLS=true
```

Then run only the realtime service if your broker/database are external:

```bash
docker compose up --build realtime
```

## HiveMQ Serverless setup

1. Sign in to HiveMQ Cloud and create a `Serverless` cluster.
2. Open `Manage Cluster` -> `Overview`.
3. Copy `URL` and `Port` from `Connection Details`.
4. Open `Access Management` and add credentials (username/password).
5. For quick bring-up, use broad permission first (publish + subscribe). Later, restrict to `sleepydrive/alerts/#`.
6. Keep those values and set your env vars:

PowerShell:

```powershell
$env:MP_QTT_HOST="<your-cluster-url>"
$env:MP_QTT_PORT="8883"
$env:MP_QTT_TOPIC="sleepydrive/alerts/+"
$env:MP_QTT_STATUS_TOPIC="sleepydrive/status/+"
$env:MP_SOURCE_ID="jetson-01"
$env:MP_QTT_USERNAME="<your-username>"
$env:MP_QTT_PASSWORD="<your-password>"
$env:MP_QTT_TLS="true"
```

Linux/macOS:

```bash
export MP_QTT_HOST="<your-cluster-url>"
export MP_QTT_PORT="8883"
export MP_QTT_TOPIC="sleepydrive/alerts/+"
export MP_QTT_STATUS_TOPIC="sleepydrive/status/+"
export MP_SOURCE_ID="jetson-01"
export MP_QTT_USERNAME="<your-username>"
export MP_QTT_PASSWORD="<your-password>"
export MP_QTT_TLS="true"
```

Then start the gateway:

```bash
docker compose up --build realtime
```

## Local run (without Docker)

Start Postgres + Mosquitto first, then:

```bash
pip install -r requirements.txt
uvicorn app:app --host 0.0.0.0 --port 8080 --reload
```

On Windows with Python 3.13, prefer:

```bash
python run_server.py
```

## Jetson uplink publisher example

Use the helper publisher:

```bash
python jetson_mqtt_uplink.py --mqtt-host localhost --device-id jetson-01 --level 2 --message "Drowsiness detected"
```

## Jetson detection callback wiring (drop-in)

Import and connect once at process startup:

```python
from jetson_alert_dispatcher import JetsonAlertDispatcher

dispatcher = JetsonAlertDispatcher.from_env()
dispatcher.connect()
```

`connect()` now also publishes a retained online presence event and sets an MQTT last-will offline presence event.

Call this in your detection callback:

```python
dispatcher.publish_alert(
    level=2,
    message="Drowsiness detected",
    metadata={"ear": 0.17, "blink_ms": 2300},
)
```

Shutdown cleanly on process exit:

```python
dispatcher.close()
```

`close()` publishes an offline presence event.

Expected log for each event:

```text
publish_alert rc=0 ok=True topic=sleepydrive/alerts/jetson-01 ...
```

Presence logs:

```text
publish_presence rc=0 ok=True topic=sleepydrive/status/jetson-01 ...
```

## Flutter client URL

Point your app websocket URL at the gateway:

```text
ws://<gateway-host>:8080/ws/alerts
```

Use `wss://...` when exposing over TLS.
