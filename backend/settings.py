from __future__ import annotations

import os
from dataclasses import dataclass


def _first_env(names: tuple[str, ...], default: str) -> str:
    for name in names:
        raw = os.getenv(name)
        if raw is not None and raw.strip():
            return raw.strip()
    return default


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
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


def _derive_status_topic(alert_topic: str) -> str:
    topic = alert_topic.strip()
    if not topic:
        return "sleepydrive/status/+"
    if "/alerts/" in topic:
        return topic.replace("/alerts/", "/status/")
    if topic.endswith("/alerts/+"):
        return f"{topic[:-9]}/status/+"
    if topic.endswith("/alerts/#"):
        return f"{topic[:-9]}/status/#"
    return "sleepydrive/status/+"


def _env_optional_secret(names: tuple[str, ...]) -> str | None:
    for name in names:
        raw = os.getenv(name)
        if raw is not None and raw.strip():
            return raw.strip()
    return None


def _trusted_hosts_from_env() -> tuple[str, ...]:
    raw = os.getenv("TRUSTED_HOSTS", "*")
    hosts = tuple(part.strip() for part in raw.split(",") if part.strip())
    return hosts if hosts else ("*",)


@dataclass(frozen=True)
class Settings:
    app_host: str
    app_port: int
    database_url: str
    mqtt_host: str
    mqtt_port: int
    mqtt_username: str | None
    mqtt_password: str | None
    mqtt_client_id: str
    mqtt_qos: int
    mqtt_reconnect_seconds: int
    mqtt_topics: tuple[str, ...]
    mqtt_tls_enabled: bool
    mqtt_tls_insecure: bool
    mqtt_ca_cert: str | None
    mqtt_client_cert: str | None
    mqtt_client_key: str | None
    ws_default_replay: int
    ws_idle_ping_seconds: int
    gateway_api_key: str | None
    trusted_hosts: tuple[str, ...]
    max_mqtt_payload_bytes: int
    ws_max_incoming_bytes: int
    db_command_timeout_seconds: float
    cors_allow_origins: tuple[str, ...]

    @classmethod
    def from_env(cls) -> "Settings":
        topics_raw = _first_env(("MQTT_TOPICS", "MP_QTT_TOPIC"), "sleepydrive/alerts/+")
        alert_topics = tuple(part.strip() for part in topics_raw.split(",") if part.strip())
        if not alert_topics:
            alert_topics = ("sleepydrive/alerts/+",)

        status_topics_raw = _first_env(("MQTT_STATUS_TOPICS", "MP_QTT_STATUS_TOPIC"), "")
        if status_topics_raw.strip():
            status_topics = tuple(part.strip() for part in status_topics_raw.split(",") if part.strip())
        else:
            status_topics = tuple(_derive_status_topic(topic) for topic in alert_topics)

        # Preserve order and deduplicate.
        topics = tuple(dict.fromkeys((*alert_topics, *status_topics)))

        cors_raw = os.getenv("CORS_ALLOW_ORIGINS", "*")
        cors_allow_origins = tuple(part.strip() for part in cors_raw.split(",") if part.strip())
        if not cors_allow_origins:
            cors_allow_origins = ("*",)

        username = _first_env(("MQTT_USERNAME", "MP_QTT_USERNAME"), "").strip()
        password = _first_env(("MQTT_PASSWORD", "MP_QTT_PASSWORD"), "").strip()
        tls_enabled = _env_bool_names(("MQTT_TLS", "MP_QTT_TLS"), False)
        tls_insecure = _env_bool_names(("MQTT_TLS_INSECURE", "MP_QTT_TLS_INSECURE"), False)
        ca_cert = _first_env(("MQTT_CA_CERT", "MP_QTT_CA_CERT"), "").strip()
        client_cert = _first_env(("MQTT_CLIENT_CERT", "MP_QTT_CLIENT_CERT"), "").strip()
        client_key = _first_env(("MQTT_CLIENT_KEY", "MP_QTT_CLIENT_KEY"), "").strip()

        api_key = _env_optional_secret(("GATEWAY_API_KEY", "API_KEY"))

        max_mqtt = max(4096, _env_int("MAX_MQTT_PAYLOAD_BYTES", 262_144))
        ws_in = max(256, _env_int("WS_MAX_INCOMING_BYTES", 16_384))
        db_timeout = max(5.0, float(_env_int("DB_COMMAND_TIMEOUT_SECONDS", 60)))

        return cls(
            app_host=os.getenv("APP_HOST", "0.0.0.0"),
            app_port=_env_int("APP_PORT", 8080),
            database_url=os.getenv(
                "DATABASE_URL",
                "postgresql://sleepydrive:sleepydrive@localhost:5432/sleepydrive",
            ),
            mqtt_host=_first_env(("MQTT_HOST", "MP_QTT_HOST"), "localhost"),
            mqtt_port=_env_int_names(("MQTT_PORT", "MP_QTT_PORT"), 1883),
            mqtt_username=username if username else None,
            mqtt_password=password if password else None,
            mqtt_client_id=_first_env(("MQTT_CLIENT_ID", "MP_QTT_CLIENT_ID"), "sleepydrive-realtime-gateway"),
            mqtt_qos=max(0, min(_env_int_names(("MQTT_QOS", "MP_QTT_QOS"), 1), 2)),
            mqtt_reconnect_seconds=max(1, _env_int_names(("MQTT_RECONNECT_SECONDS", "MP_QTT_RECONNECT_SECONDS"), 3)),
            mqtt_topics=topics,
            mqtt_tls_enabled=tls_enabled,
            mqtt_tls_insecure=tls_insecure,
            mqtt_ca_cert=ca_cert if ca_cert else None,
            mqtt_client_cert=client_cert if client_cert else None,
            mqtt_client_key=client_key if client_key else None,
            ws_default_replay=max(0, _env_int("WS_DEFAULT_REPLAY", 25)),
            ws_idle_ping_seconds=max(0, _env_int("WS_IDLE_PING_SECONDS", 30)),
            gateway_api_key=api_key,
            trusted_hosts=_trusted_hosts_from_env(),
            max_mqtt_payload_bytes=max_mqtt,
            ws_max_incoming_bytes=ws_in,
            db_command_timeout_seconds=db_timeout,
            cors_allow_origins=cors_allow_origins,
        )
