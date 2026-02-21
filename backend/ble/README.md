# SleepyDrive — BLE Alert Server (Jetson)

Sends drowsiness alerts to your phone over Bluetooth Low Energy.  
Your phone uses **nRF Connect** (free app) to receive them.

## Files

| File | Purpose |
|------|---------|
| `config.py` | Device name + BLE UUIDs |
| `ble_notifier.py` | GATT server (runs on Jetson) |
| `ble_test.py` | Test script — sends alerts every 5s |

## Quick Start

### 1. Copy this folder to the Jetson

```bash
scp -r backend/ble/ jetson@<JETSON_IP>:~/sleepydrive_ble/
```

### 2. Install dependencies (on the Jetson)

```bash
sudo apt-get install -y bluetooth bluez python3-dbus python3-gi
```

BlueZ and D-Bus come pre-installed on most Jetson images.

### 3. Run the test

```bash
cd ~/sleepydrive_ble
sudo python3 ble_test.py
```

### 4. Connect from your phone

1. Open **nRF Connect** on your phone
2. Tap **Scan**
3. Find **"SleepyDrive"** in the device list → tap **Connect**
4. Expand the service (UUID: `12345678-1234-5678-1234-56789abcdef0`)
5. Tap the **↓ arrow** on the characteristic to subscribe to notifications
6. You should see test messages arriving every 5 seconds! 🎉

### Alert format

Notifications arrive as UTF-8 text in this format:

```
<level>|<message>
```

| Level | Meaning |
|-------|---------|
| `0` | Safe — no drowsiness |
| `1` | Warning — driver may be drowsy |
| `2` | Danger — drowsiness detected! |

Example: `2|drowsiness detected — blink rate elevated`

## Using in your own code

```python
from ble_notifier import BLENotifier

notifier = BLENotifier()
notifier.start()

# Send an alert
notifier.send_alert(2, "drowsiness detected!")

# Clean up
notifier.stop()
```
