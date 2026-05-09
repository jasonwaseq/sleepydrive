import argparse
import asyncio
import json

try:
    import aiomqtt
except ImportError:
    print("Please install aiomqtt: pip install aiomqtt")
    exit(1)


async def inject_event(
    host: str,
    port: int,
    device_id: str,
    level: int,
    message: str,
    risk: int,
):
    """
    Publishes a fake MQTT drowsiness event to the broker.
    """
    topic = f"sleepydrive/alerts/{device_id}"
    payload = {
        "device_id": device_id,
        "level": level,
        "message": message,
        "risk": risk,
    }
    print(f"Connecting to MQTT broker at {host}:{port}...")
    async with aiomqtt.Client(host, port) as client:
        print(f"Publishing to {topic}: {payload}")
        await client.publish(topic, payload=json.dumps(payload).encode("utf-8"))
        print("Event injected successfully.")


def main():
    parser = argparse.ArgumentParser(description="Inject a fake drowsiness event via MQTT")
    parser.add_argument("--host", default="localhost", help="MQTT broker host")
    parser.add_argument("--port", type=int, default=1883, help="MQTT broker port")
    parser.add_argument("--device", default="test-device-1", help="Device ID")
    parser.add_argument("--level", type=int, default=2, help="Alert level (0=safe, 1=warn, 2=danger)")
    parser.add_argument("--message", default="Drowsiness detected (Simulated)", help="Alert message text")
    parser.add_argument("--risk", type=int, default=85, help="Fatigue risk percentage (0-100)")
    args = parser.parse_args()

    asyncio.run(inject_event(
        host=args.host,
        port=args.port,
        device_id=args.device,
        level=args.level,
        message=args.message,
        risk=args.risk,
    ))


if __name__ == "__main__":
    main()
