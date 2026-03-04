from __future__ import annotations

import argparse
import json
import os
import socket
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _first_env(names: tuple[str, ...], default: str) -> str:
    for name in names:
        raw = os.getenv(name)
        if raw is not None and raw.strip():
            return raw.strip()
    return default


def _env_int_names(names: tuple[str, ...], default: int) -> int:
    for name in names:
        raw = os.getenv(name)
        if raw is None:
            continue
        try:
            return int(raw)
        except ValueError:
            continue
    return default


def _env_bool_names(names: tuple[str, ...], default: bool) -> bool:
    truthy = {"1", "true", "yes", "on"}
    falsy = {"0", "false", "no", "off"}
    for name in names:
        raw = os.getenv(name)
        if raw is None:
            continue
        value = raw.strip().lower()
        if value in truthy:
            return True
        if value in falsy:
            return False
    return default


def _default_topic_prefix() -> str:
    raw = _first_env(("MQTT_TOPICS", "MP_QTT_TOPIC"), "sleepydrive/alerts/+")
    first = raw.split(",")[0].strip() if raw else "sleepydrive/alerts/+"
    if not first:
        first = "sleepydrive/alerts/+"
    return first.replace("/+", "")


def _default_source_id() -> str:
    return _first_env(("MP_SOURCE_ID", "SOURCE_ID"), socket.gethostname())


def build_payload(device_id: str, level: int, message: str, source: str) -> str:
    payload = {
        "device_id": device_id,
        "level": level,
        "message": message,
        "source": source,
        "event_ts": _utc_iso(),
    }
    return json.dumps(payload, separators=(",", ":"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish Jetson alerts to MQTT")
    parser.add_argument("--mqtt-host", default=_first_env(("MQTT_HOST", "MP_QTT_HOST"), "localhost"))
    parser.add_argument("--mqtt-port", type=int, default=_env_int_names(("MQTT_PORT", "MP_QTT_PORT"), 1883))
    parser.add_argument("--mqtt-username", default=_first_env(("MQTT_USERNAME", "MP_QTT_USERNAME"), ""))
    parser.add_argument("--mqtt-password", default=_first_env(("MQTT_PASSWORD", "MP_QTT_PASSWORD"), ""))
    parser.add_argument("--mqtt-tls", action="store_true", default=_env_bool_names(("MQTT_TLS", "MP_QTT_TLS"), False))
    parser.add_argument("--mqtt-tls-insecure", action="store_true", default=_env_bool_names(("MQTT_TLS_INSECURE", "MP_QTT_TLS_INSECURE"), False))
    parser.add_argument("--mqtt-ca-cert", default=_first_env(("MQTT_CA_CERT", "MP_QTT_CA_CERT"), ""))
    parser.add_argument("--mqtt-client-cert", default=_first_env(("MQTT_CLIENT_CERT", "MP_QTT_CLIENT_CERT"), ""))
    parser.add_argument("--mqtt-client-key", default=_first_env(("MQTT_CLIENT_KEY", "MP_QTT_CLIENT_KEY"), ""))
    parser.add_argument("--device-id", default=_default_source_id())
    parser.add_argument("--source", default="jetson")
    parser.add_argument("--topic-prefix", default=_default_topic_prefix())
    parser.add_argument("--level", type=int, default=1, choices=[0, 1, 2])
    parser.add_argument("--message", default="Drowsiness warning")
    parser.add_argument("--count", type=int, default=1, help="0 for infinite publish loop")
    parser.add_argument("--interval", type=float, default=1.0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    topic = f"{args.topic_prefix}/{args.device_id}"
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"uplink-{args.device_id}")
    if args.mqtt_username:
        client.username_pw_set(args.mqtt_username, args.mqtt_password)
    if args.mqtt_tls:
        tls_kwargs = {}
        if args.mqtt_ca_cert:
            tls_kwargs["ca_certs"] = args.mqtt_ca_cert
        if args.mqtt_client_cert:
            tls_kwargs["certfile"] = args.mqtt_client_cert
        if args.mqtt_client_key:
            tls_kwargs["keyfile"] = args.mqtt_client_key
        client.tls_set(**tls_kwargs)
        if args.mqtt_tls_insecure:
            client.tls_insecure_set(True)

    client.connect(args.mqtt_host, args.mqtt_port, keepalive=30)
    client.loop_start()
    try:
        sent = 0
        while args.count == 0 or sent < args.count:
            payload = build_payload(
                device_id=args.device_id,
                level=args.level,
                message=args.message,
                source=args.source,
            )
            info = client.publish(topic, payload=payload, qos=1, retain=False)
            info.wait_for_publish()
            sent += 1
            print(f"published {sent} topic={topic} payload={payload}")
            if args.count == 0 or sent < args.count:
                time.sleep(max(args.interval, 0.1))
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
