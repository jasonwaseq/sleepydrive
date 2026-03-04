from __future__ import annotations

import json
import logging
import os
import socket
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

log = logging.getLogger("realtime.jetson_dispatcher")


def _first_env(names: tuple[str, ...], default: str) -> str:
    for name in names:
        raw = os.getenv(name)
        if raw is not None and raw.strip():
            return raw.strip()
    return default


def _env_int(names: tuple[str, ...], default: int) -> int:
    for name in names:
        raw = os.getenv(name)
        if raw is None:
            continue
        try:
            return int(raw)
        except ValueError:
            continue
    return default


def _env_bool(names: tuple[str, ...], default: bool) -> bool:
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
    raw = _first_env(("MP_QTT_TOPIC", "MQTT_TOPICS"), "sleepydrive/alerts/+")
    first = raw.split(",")[0].strip() if raw else "sleepydrive/alerts/+"
    if not first:
        first = "sleepydrive/alerts/+"
    return first.replace("/+", "")


def _derive_status_topic_prefix(alert_topic_prefix: str) -> str:
    if "/alerts/" in alert_topic_prefix:
        return alert_topic_prefix.replace("/alerts/", "/status/")
    if alert_topic_prefix.endswith("/alerts"):
        return f"{alert_topic_prefix[:-7]}/status"
    return "sleepydrive/status"


def _utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class JetsonAlertDispatcher:
    """
    Drop-in MQTT publisher for Jetson detection callbacks.

    Usage:
        dispatcher = JetsonAlertDispatcher.from_env()
        dispatcher.connect()
        dispatcher.publish_alert(level=2, message="Drowsiness detected")
        dispatcher.close()
    """

    def __init__(
        self,
        *,
        broker_host: str,
        broker_port: int,
        topic_prefix: str,
        status_topic_prefix: str,
        source_id: str,
        username: str | None = None,
        password: str | None = None,
        tls_enabled: bool = False,
        tls_insecure: bool = False,
        qos: int = 1,
        retain: bool = False,
        source: str = "jetson",
        client_id: str | None = None,
    ):
        self.broker_host = broker_host
        self.broker_port = broker_port
        self.topic_prefix = topic_prefix.rstrip("/")
        self.status_topic_prefix = status_topic_prefix.rstrip("/")
        self.source_id = source_id
        self.username = username
        self.password = password
        self.tls_enabled = tls_enabled
        self.tls_insecure = tls_insecure
        self.qos = max(0, min(qos, 2))
        self.retain = retain
        self.source = source
        self.client_id = client_id or f"uplink-{source_id}"
        self._client: mqtt.Client | None = None

    @classmethod
    def from_env(cls) -> "JetsonAlertDispatcher":
        source_id = _first_env(("MP_SOURCE_ID", "SOURCE_ID"), socket.gethostname())
        return cls(
            broker_host=_first_env(("MP_QTT_HOST", "MQTT_HOST"), "localhost"),
            broker_port=_env_int(("MP_QTT_PORT", "MQTT_PORT"), 1883),
            topic_prefix=_default_topic_prefix(),
            status_topic_prefix=_first_env(
                ("MP_QTT_STATUS_TOPIC", "MQTT_STATUS_TOPICS"),
                _derive_status_topic_prefix(_default_topic_prefix()),
            )
            .split(",")[0]
            .replace("/+", "")
            .replace("/#", ""),
            source_id=source_id,
            username=_first_env(("MP_QTT_USERNAME", "MQTT_USERNAME"), "") or None,
            password=_first_env(("MP_QTT_PASSWORD", "MQTT_PASSWORD"), "") or None,
            tls_enabled=_env_bool(("MP_QTT_TLS", "MQTT_TLS"), False),
            tls_insecure=_env_bool(("MP_QTT_TLS_INSECURE", "MQTT_TLS_INSECURE"), False),
            qos=_env_int(("MP_QTT_QOS", "MQTT_QOS"), 1),
            retain=_env_bool(("MP_QTT_RETAIN", "MQTT_RETAIN"), False),
            source=_first_env(("MP_SOURCE", "SOURCE"), "jetson"),
            client_id=_first_env(("MP_QTT_CLIENT_ID", "MQTT_CLIENT_ID"), f"uplink-{source_id}"),
        )

    @property
    def topic(self) -> str:
        return f"{self.topic_prefix}/{self.source_id}"

    @property
    def status_topic(self) -> str:
        return f"{self.status_topic_prefix}/{self.source_id}"

    def connect(self) -> None:
        if self._client is not None:
            return

        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=self.client_id)
        if self.username:
            client.username_pw_set(self.username, self.password)
        if self.tls_enabled:
            client.tls_set()
            if self.tls_insecure:
                client.tls_insecure_set(True)

        # Publish an offline status if this client disconnects unexpectedly.
        offline_payload = json.dumps(
            {
                "type": "presence",
                "source_id": self.source_id,
                "online": False,
                "source": self.source,
                "event_ts": _utc_iso(),
            },
            separators=(",", ":"),
        )
        client.will_set(self.status_topic, payload=offline_payload, qos=self.qos, retain=True)

        client.connect(self.broker_host, self.broker_port, keepalive=30)
        client.loop_start()
        self._client = client
        self.publish_presence(online=True, metadata={"state": "connected"}, retain=True)
        log.info(
            "Jetson dispatcher connected host=%s port=%s tls=%s topic=%s status_topic=%s",
            self.broker_host,
            self.broker_port,
            self.tls_enabled,
            self.topic,
            self.status_topic,
        )

    def publish_alert(self, *, level: int, message: str, metadata: dict | None = None) -> bool:
        if self._client is None:
            self.connect()
        assert self._client is not None

        payload = {
            "device_id": self.source_id,
            "level": max(0, min(int(level), 2)),
            "message": message or "Alert",
            "source": self.source,
            "event_ts": _utc_iso(),
        }
        if metadata:
            payload["metadata"] = metadata
        payload_str = json.dumps(payload, separators=(",", ":"))

        info = self._client.publish(self.topic, payload=payload_str, qos=self.qos, retain=self.retain)
        info.wait_for_publish(timeout=5.0)

        ok = info.rc == mqtt.MQTT_ERR_SUCCESS
        log.info(
            "publish_alert rc=%s ok=%s topic=%s mid=%s payload=%s",
            info.rc,
            ok,
            self.topic,
            info.mid,
            payload_str,
        )
        return ok

    def publish_presence(self, *, online: bool, metadata: dict | None = None, retain: bool = True) -> bool:
        if self._client is None:
            self.connect()
        assert self._client is not None

        payload = {
            "type": "presence",
            "source_id": self.source_id,
            "online": bool(online),
            "source": self.source,
            "event_ts": _utc_iso(),
        }
        if metadata:
            payload["metadata"] = metadata
        payload_str = json.dumps(payload, separators=(",", ":"))

        info = self._client.publish(self.status_topic, payload=payload_str, qos=self.qos, retain=retain)
        info.wait_for_publish(timeout=5.0)
        ok = info.rc == mqtt.MQTT_ERR_SUCCESS
        log.info(
            "publish_presence rc=%s ok=%s topic=%s mid=%s payload=%s",
            info.rc,
            ok,
            self.status_topic,
            info.mid,
            payload_str,
        )
        return ok

    def close(self) -> None:
        if self._client is None:
            return
        try:
            self.publish_presence(online=False, metadata={"state": "closed"}, retain=True)
            # Give in-flight publishes a small flush window.
            time.sleep(0.1)
            self._client.loop_stop()
            self._client.disconnect()
        finally:
            self._client = None
