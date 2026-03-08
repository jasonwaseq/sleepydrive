import asyncio
import json
import random
import time
import websockets
from datetime import datetime, timezone

# 1. Use "0.0.0.0" to listen on ALL interfaces (Wi-Fi, Ethernet, Localhost).
# This is much more reliable than binding to a specific IP.
LISTEN_IP = "0.0.0.0" 

# Just for the print statement at the end
PRINT_IP = input("Enter your computer's IP (from hostname -I): ")

def utc_timestamp():
    return datetime.now(timezone.utc).isoformat()

class JetsonSimulator:
    def __init__(self, source_id="jetson-01"):
        self.source_id = source_id

    def get_heartbeat(self):
        return {
            "type": "heartbeat",
            "source_id": self.source_id,
            "online": True,
            "event_ts": utc_timestamp()
        }

    def get_alert(self):
        levels = [0, 1, 2]
        messages = [
            "Driver is focused", 
            "Drowsiness detected - Warning", 
            "CRITICAL: Driver asleep!"
        ]
        idx = random.choices([0, 1, 2], weights=[0.6, 0.3, 0.1])[0]
        
        return {
            "type": "alert",
            "level": levels[idx],
            "message": messages[idx],
            "timestamp": utc_timestamp(),
            "source_id": self.source_id
        }

# FIX: Added 'path' argument. 
# Without this, the script will crash because your Flutter app connects to "/ws/alerts"
async def handler(websocket, path): 
    print(f"Flutter app connected! (Path: {path})")
    sim = JetsonSimulator()
    
    try:
        # 1. Send initial presence
        await websocket.send(json.dumps({
            "type": "presence",
            "source_id": "jetson-01",
            "online": True,
            "event_ts": utc_timestamp()
        }))

        last_alert_time = time.time()
        
        while True:
            # 2. Send Heartbeat
            await websocket.send(json.dumps(sim.get_heartbeat()))
            print("Sent: Heartbeat")

            # 3. Send random alert
            if time.time() - last_alert_time > random.randint(10, 15):
                alert = sim.get_alert()
                await websocket.send(json.dumps(alert))
                print(f"Sent Alert: {alert['message']}")
                last_alert_time = time.time()

            await asyncio.sleep(5)
            
    except websockets.exceptions.ConnectionClosed:
        print("Flutter app disconnected.")
    except Exception as e:
        print(f"Error: {e}")

async def main():
    # Use LISTEN_IP (0.0.0.0) here so it works on any interface
    async with websockets.serve(handler, LISTEN_IP, 8765):
        print(f"\n--- Emulator Running ---")
        print(f"Connect your Flutter app to: ws://{PRINT_IP}:8765/ws/alerts?replay=0")
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nStopping Emulator...")
