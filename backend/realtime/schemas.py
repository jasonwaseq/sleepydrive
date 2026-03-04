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
                device_id=str(obj.get("device_id") or default_device),
                level=_coerce_level(obj.get("level") or obj.get("severity") or obj.get("risk")),
                message=str(obj.get("message") or obj.get("msg") or obj.get("alert") or obj.get("text") or "Alert"),
                source=str(obj.get("source") or "jetson"),
                topic=str(obj.get("topic") or topic),
                event_ts=_parse_ts(obj.get("event_ts") or obj.get("timestamp") or obj.get("ts")),
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

