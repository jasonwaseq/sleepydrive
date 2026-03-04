from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _parse_ts(value: Any) -> datetime:
    if value is None:
        return utcnow()

    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc)

    if isinstance(value, str):
        text = value.strip()
        if not text:
            return utcnow()
        if text.endswith("Z"):
            text = f"{text[:-1]}+00:00"
        try:
            parsed = datetime.fromisoformat(text)
        except ValueError:
            return utcnow()
        if parsed.tzinfo is None:
            return parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)

    return utcnow()


def _coerce_level(raw: Any) -> int:
    if raw is None:
        return 1

    if isinstance(raw, int):
        return max(0, min(raw, 2))

    text = str(raw).strip().lower()
    if not text:
        return 1

    as_int = int(text) if text.isdigit() else None
    if as_int is not None:
        return max(0, min(as_int, 2))

    if text in {"safe", "normal", "info"}:
        return 0
    if text in {"warning", "warn", "caution"}:
        return 1
    if text in {"danger", "critical", "alert"}:
        return 2
    return 1


def _device_from_topic(topic: str) -> str:
    parts = [part for part in topic.split("/") if part]
    if not parts:
        return "unknown"
    return parts[-1]


def _coerce_online(raw: Any, default: bool = True) -> bool:
    if isinstance(raw, bool):
        return raw
    if raw is None:
        return default
    text = str(raw).strip().lower()
    if text in {"1", "true", "yes", "on", "online", "up", "connected"}:
        return True
    if text in {"0", "false", "no", "off", "offline", "down", "disconnected"}:
        return False
    return default


def _first_present(*values: Any) -> Any:
    for value in values:
        if value is not None:
            return value
    return None


@dataclass(frozen=True)
class AlertEvent:
    device_id: str
    level: int
    message: str
    source: str
    topic: str
    event_ts: datetime
    received_ts: datetime
    metadata: dict[str, Any] = field(default_factory=dict)
    id: int | None = None

    @property
    def level_label(self) -> str:
        if self.level == 0:
            return "SAFE"
        if self.level == 1:
            return "WARNING"
        if self.level == 2:
            return "DANGER"
        return "UNKNOWN"

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "device_id": self.device_id,
            "level": self.level,
            "level_label": self.level_label,
            "message": self.message,
            "source": self.source,
            "topic": self.topic,
            "event_ts": self.event_ts.isoformat(),
            "received_ts": self.received_ts.isoformat(),
            "metadata": self.metadata,
        }


@dataclass(frozen=True)
class JetsonPresence:
    source_id: str
    online: bool
    event_ts: datetime
    topic: str
    source: str = "jetson"
    metadata: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "source_id": self.source_id,
            "online": self.online,
            "event_ts": self.event_ts.isoformat(),
            "topic": self.topic,
            "source": self.source,
            "metadata": self.metadata,
        }


def parse_presence_payload(topic: str, payload: bytes) -> JetsonPresence | None:
    text = payload.decode("utf-8", errors="replace").strip()
    if not text or not (text.startswith("{") and text.endswith("}")):
        return None

    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(obj, dict):
        return None

    type_text = str(obj.get("type") or obj.get("event_type") or "").strip().lower()
    is_status_topic = "/status/" in topic
    if type_text not in {"presence", "status", "heartbeat"} and not is_status_topic:
        return None

    source_id = str(obj.get("source_id") or obj.get("device_id") or _device_from_topic(topic))
    if type_text == "heartbeat":
        online = True
    else:
        raw_online = obj["online"] if "online" in obj else obj.get("status")
        online = _coerce_online(raw_online, default=True)

    known = {
        "type",
        "event_type",
        "source_id",
        "device_id",
        "online",
        "status",
        "event_ts",
        "timestamp",
        "ts",
        "source",
        "topic",
        "metadata",
    }
    metadata = obj.get("metadata")
    if not isinstance(metadata, dict):
        metadata = {}
    for key, value in obj.items():
        if key not in known:
            metadata[key] = value

    return JetsonPresence(
        source_id=source_id,
        online=online,
        event_ts=_parse_ts(obj.get("event_ts") or obj.get("timestamp") or obj.get("ts")),
        topic=str(obj.get("topic") or topic),
        source=str(obj.get("source") or "jetson"),
        metadata=metadata,
    )


def parse_mqtt_payload(topic: str, payload: bytes) -> AlertEvent:
    text = payload.decode("utf-8", errors="replace").strip()
    now = utcnow()
    default_device = _device_from_topic(topic)

    if text.startswith("{") and text.endswith("}"):
        try:
            obj = json.loads(text)
        except json.JSONDecodeError:
            obj = None
        if isinstance(obj, dict):
            known = {
                "device_id",
                "level",
                "severity",
                "risk",
                "message",
                "msg",
                "alert",
                "text",
                "source",
                "event_ts",
                "timestamp",
                "ts",
                "topic",
                "metadata",
            }
            metadata = obj.get("metadata")
            if not isinstance(metadata, dict):
                metadata = {}
            for key, value in obj.items():
                if key not in known:
                    metadata[key] = value

            return AlertEvent(
                device_id=str(obj.get("device_id") or obj.get("source_id") or default_device),
                level=_coerce_level(_first_present(obj.get("level"), obj.get("severity"), obj.get("risk"))),
                message=str(_first_present(obj.get("message"), obj.get("msg"), obj.get("alert"), obj.get("text")) or "Alert"),
                source=str(obj.get("source") or "jetson"),
                topic=str(obj.get("topic") or topic),
                event_ts=_parse_ts(_first_present(obj.get("event_ts"), obj.get("timestamp"), obj.get("ts"))),
                received_ts=now,
                metadata=metadata,
            )

    pipe_index = text.find("|")
    if pipe_index > 0:
        level = _coerce_level(text[:pipe_index])
        message = text[pipe_index + 1 :].strip() or "Alert"
    else:
        level = 1
        message = text or "Alert"

    return AlertEvent(
        device_id=default_device,
        level=level,
        message=message,
        source="jetson",
        topic=topic,
        event_ts=now,
        received_ts=now,
        metadata={},
    )
