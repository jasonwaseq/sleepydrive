#!/usr/bin/env python3
"""
BLE Connection Test — SleepyDrive Alert System

Starts the BLE GATT server and sends a test notification every 5 seconds.
Use this to verify your phone can connect and receive alerts via nRF Connect.

PHONE SETUP:
  1. Install "nRF Connect" (free) on your phone
  2. Run this script on the Jetson:  sudo python3 ble_test.py
  3. Open nRF Connect → tap "Scan"
  4. Find "SleepyDrive" in the list → tap "Connect"
  5. Expand the service → tap the ↓ arrow (notify) on the characteristic
  6. You should see test messages arriving every 5 seconds!

Usage:
    sudo python3 ble_test.py
"""

import sys
import time
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s │ %(levelname)-7s │ %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("ble_test")


def main():
    print()
    print("=" * 60)
    print("  🔵 BLE Connection Test — SleepyDrive Alert System")
    print("=" * 60)
    print()
    print("  📱 On your phone:")
    print("     1. Open nRF Connect")
    print("     2. Tap 'Scan'")
    print("     3. Find 'SleepyDrive' → tap 'Connect'")
    print("     4. Expand the service listed")
    print("     5. Tap the ↓ arrow on the characteristic")
    print("        to subscribe to notifications")
    print()
    print("  Ctrl+C to stop")
    print("=" * 60)
    print()

    # Start BLE server
    log.info("Starting BLE GATT server...")
    try:
        from ble_notifier import BLENotifier
        notifier = BLENotifier()
        notifier.start()
    except Exception as e:
        log.error("BLE failed to start: %s", e)
        log.error("Make sure you're running with sudo!")
        sys.exit(1)

    log.info("✅ BLE server is running — device name: 'SleepyDrive'")
    log.info("Waiting for phone connection...")
    print()

    # Send test notifications every 5 seconds
    count = 0
    try:
        while True:
            time.sleep(5)
            count += 1

            # Alternate between warning and danger test messages
            if count % 2 == 1:
                level = 1  # WARNING
                msg = f"Test WARNING #{count} — driver may be drowsy!"
            else:
                level = 2  # DANGER
                msg = f"Test DANGER #{count} — drowsiness detected!"

            notifier.send_alert(level, msg)
            log.info("📤 Sent: [%s] %s",
                     "WARNING" if level == 1 else "DANGER", msg)

    except KeyboardInterrupt:
        print()
        log.info("Stopping BLE server...")
        notifier.stop()
        log.info("Done! 👋")


if __name__ == "__main__":
    main()
