from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest

from schemas import (
    MAX_JSON_KEY_CHARS,
    MAX_METADATA_KEYS,
    MAX_METADATA_VALUE_CHARS,
    AlertEvent,
    JetsonPresence,
    _clamp_str,
    _coerce_level,
    _coerce_online,
    _coerce_percent,
    _device_from_topic,
    _first_present,
    _sanitize_metadata,
    parse_mqtt_payload,
    parse_presence_payload,
    utcnow,
    _parse_ts,
)


# ---------------------------------------------------------------------------
# _clamp_str
# ---------------------------------------------------------------------------

def test_clamp_str_short():
    assert _clamp_str("hello", 10) == "hello"


def test_clamp_str_exact():
    assert _clamp_str("hello", 5) == "hello"


def test_clamp_str_truncates():
    assert _clamp_str("hello world", 5) == "hello"


# ---------------------------------------------------------------------------
# _sanitize_metadata
# ---------------------------------------------------------------------------

def test_sanitize_metadata_scalar_types():
    raw = {"i": 1, "f": 3.14, "b": True, "n": None}
    out = _sanitize_metadata(raw)
    assert out == {"i": 1, "f": 3.14, "b": True, "n": None}


def test_sanitize_metadata_string_truncated():
    long_val = "x" * (MAX_METADATA_VALUE_CHARS + 100)
    out = _sanitize_metadata({"k": long_val})
    assert len(out["k"]) == MAX_METADATA_VALUE_CHARS


def test_sanitize_metadata_key_truncated():
    long_key = "k" * (MAX_JSON_KEY_CHARS + 50)
    out = _sanitize_metadata({long_key: "v"})
    assert list(out.keys())[0] == "k" * MAX_JSON_KEY_CHARS


def test_sanitize_metadata_key_cap():
    raw = {str(i): i for i in range(MAX_METADATA_KEYS + 10)}
    out = _sanitize_metadata(raw)
    assert len(out) == MAX_METADATA_KEYS


def test_sanitize_metadata_non_scalar_stringified():
    out = _sanitize_metadata({"lst": [1, 2, 3], "dct": {"a": 1}})
    assert out["lst"] == "[1, 2, 3]"
    assert out["dct"] == "{'a': 1}"


# ---------------------------------------------------------------------------
# _parse_ts
# ---------------------------------------------------------------------------

def test_parse_ts_none_returns_utcnow():
    before = utcnow()
    result = _parse_ts(None)
    after = utcnow()
    assert before <= result <= after
    assert result.tzinfo is not None


def test_parse_ts_unix_int():
    result = _parse_ts(0)
    assert result == datetime(1970, 1, 1, tzinfo=timezone.utc)


def test_parse_ts_unix_float():
    result = _parse_ts(0.5)
    assert result == datetime(1970, 1, 1, 0, 0, 0, 500000, tzinfo=timezone.utc)


def test_parse_ts_iso_z_suffix():
    result = _parse_ts("2024-01-01T12:00:00Z")
    assert result == datetime(2024, 1, 1, 12, 0, 0, tzinfo=timezone.utc)


def test_parse_ts_iso_with_offset():
    result = _parse_ts("2024-01-01T12:00:00+05:00")
    assert result == datetime(2024, 1, 1, 7, 0, 0, tzinfo=timezone.utc)


def test_parse_ts_iso_naive_gets_utc():
    result = _parse_ts("2024-06-15T10:00:00")
    assert result.tzinfo == timezone.utc
    assert result.year == 2024 and result.month == 6 and result.day == 15


def test_parse_ts_naive_datetime_gets_utc():
    naive = datetime(2024, 3, 1, 9, 0, 0)
    result = _parse_ts(naive)
    assert result.tzinfo == timezone.utc
    assert result.replace(tzinfo=None) == naive


def test_parse_ts_aware_datetime_converts():
    from datetime import timezone as tz
    aware = datetime(2024, 1, 1, 12, 0, 0, tzinfo=timezone(timedelta(hours=5)))
    result = _parse_ts(aware)
    assert result.tzinfo == timezone.utc
    assert result == datetime(2024, 1, 1, 7, 0, 0, tzinfo=timezone.utc)


def test_parse_ts_invalid_string_returns_utcnow():
    before = utcnow()
    result = _parse_ts("not-a-date")
    after = utcnow()
    assert before <= result <= after


def test_parse_ts_empty_string_returns_utcnow():
    before = utcnow()
    result = _parse_ts("   ")
    after = utcnow()
    assert before <= result <= after


# ---------------------------------------------------------------------------
# _coerce_level
# ---------------------------------------------------------------------------

def test_coerce_level_none():
    assert _coerce_level(None) == 1


def test_coerce_level_int_clamped_low():
    assert _coerce_level(-5) == 0


def test_coerce_level_int_clamped_high():
    assert _coerce_level(99) == 2


def test_coerce_level_valid_ints():
    assert _coerce_level(0) == 0
    assert _coerce_level(1) == 1
    assert _coerce_level(2) == 2


def test_coerce_level_string_digits():
    assert _coerce_level("0") == 0
    assert _coerce_level("1") == 1
    assert _coerce_level("2") == 2
    assert _coerce_level("9") == 2


def test_coerce_level_string_safe_labels():
    assert _coerce_level("safe") == 0
    assert _coerce_level("normal") == 0
    assert _coerce_level("info") == 0


def test_coerce_level_string_warning_labels():
    assert _coerce_level("warning") == 1
    assert _coerce_level("warn") == 1
    assert _coerce_level("caution") == 1


def test_coerce_level_string_danger_labels():
    assert _coerce_level("danger") == 2
    assert _coerce_level("critical") == 2
    assert _coerce_level("alert") == 2


def test_coerce_level_unknown_string():
    assert _coerce_level("banana") == 1


# ---------------------------------------------------------------------------
# _coerce_online
# ---------------------------------------------------------------------------

def test_coerce_online_bool_passthrough():
    assert _coerce_online(True) is True
    assert _coerce_online(False) is False


def test_coerce_online_truthy_strings():
    for val in ("1", "true", "yes", "on", "online", "up", "connected"):
        assert _coerce_online(val) is True, f"expected True for {val!r}"


def test_coerce_online_falsy_strings():
    for val in ("0", "false", "no", "off", "offline", "down", "disconnected"):
        assert _coerce_online(val) is False, f"expected False for {val!r}"


def test_coerce_online_none_uses_default():
    assert _coerce_online(None, default=True) is True
    assert _coerce_online(None, default=False) is False


def test_coerce_online_unknown_uses_default():
    assert _coerce_online("maybe", default=True) is True
    assert _coerce_online("maybe", default=False) is False


# ---------------------------------------------------------------------------
# _coerce_percent
# ---------------------------------------------------------------------------

def test_coerce_percent_none():
    assert _coerce_percent(None) is None


def test_coerce_percent_bool():
    assert _coerce_percent(True) is None
    assert _coerce_percent(False) is None


def test_coerce_percent_fractional_scales():
    assert _coerce_percent(0.5) == 50
    assert _coerce_percent(1.0) == 100


def test_coerce_percent_negative_clamps():
    assert _coerce_percent(-10) == 0


def test_coerce_percent_over_100_clamps():
    assert _coerce_percent(150) == 100


def test_coerce_percent_string_with_suffix():
    assert _coerce_percent("75%") == 75


def test_coerce_percent_invalid_string():
    assert _coerce_percent("abc") is None


# ---------------------------------------------------------------------------
# _device_from_topic
# ---------------------------------------------------------------------------

def test_device_from_topic_multi_segment():
    assert _device_from_topic("sleepydrive/alerts/jetson-1") == "jetson-1"


def test_device_from_topic_empty():
    assert _device_from_topic("") == "unknown"
    assert _device_from_topic("///") == "unknown"


# ---------------------------------------------------------------------------
# _first_present
# ---------------------------------------------------------------------------

def test_first_present_returns_first_nonnone():
    assert _first_present(None, None, "x", "y") == "x"


def test_first_present_all_none():
    assert _first_present(None, None, None) is None


# ---------------------------------------------------------------------------
# AlertEvent
# ---------------------------------------------------------------------------

def test_alert_event_level_label():
    def make(level):
        return AlertEvent(
            device_id="d", level=level, message="m", source="s",
            topic="t", event_ts=utcnow(), received_ts=utcnow(),
        )
    assert make(0).level_label == "SAFE"
    assert make(1).level_label == "WARNING"
    assert make(2).level_label == "DANGER"
    assert make(99).level_label == "UNKNOWN"


def test_alert_event_as_dict_fields():
    ts = datetime(2024, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    event = AlertEvent(
        device_id="dev-1", level=2, message="test alert",
        source="jetson", topic="sleepydrive/alerts/dev-1",
        event_ts=ts, received_ts=ts, metadata={"key": "val"}, id=42,
    )
    d = event.as_dict()
    assert d["device_id"] == "dev-1"
    assert d["level"] == 2
    assert d["level_label"] == "DANGER"
    assert d["message"] == "test alert"
    assert d["source"] == "jetson"
    assert d["topic"] == "sleepydrive/alerts/dev-1"
    assert d["event_ts"] == ts.isoformat()
    assert d["received_ts"] == ts.isoformat()
    assert d["metadata"] == {"key": "val"}
    assert d["id"] == 42


# ---------------------------------------------------------------------------
# JetsonPresence
# ---------------------------------------------------------------------------

def test_jetson_presence_as_dict_fields():
    ts = datetime(2024, 6, 1, 0, 0, 0, tzinfo=timezone.utc)
    presence = JetsonPresence(
        source_id="jetson-1", online=True, event_ts=ts,
        topic="sleepydrive/status/jetson-1", source="jetson",
        metadata={"version": "1.0"},
    )
    d = presence.as_dict()
    assert d["source_id"] == "jetson-1"
    assert d["online"] is True
    assert d["event_ts"] == ts.isoformat()
    assert d["topic"] == "sleepydrive/status/jetson-1"
    assert d["source"] == "jetson"
    assert d["metadata"] == {"version": "1.0"}


# ---------------------------------------------------------------------------
# parse_mqtt_payload
# ---------------------------------------------------------------------------

def test_parse_mqtt_payload_json_all_fields():
    payload = json.dumps({
        "device_id": "jetson-1",
        "level": 2,
        "message": "Drowsiness detected",
        "source": "mediapipe",
        "topic": "sleepydrive/alerts/jetson-1",
        "event_ts": "2024-01-01T00:00:00Z",
    }).encode()
    event = parse_mqtt_payload("sleepydrive/alerts/jetson-1", payload)
    assert event.device_id == "jetson-1"
    assert event.level == 2
    assert event.message == "Drowsiness detected"
    assert event.source == "mediapipe"
    assert event.topic == "sleepydrive/alerts/jetson-1"
    assert event.event_ts == datetime(2024, 1, 1, tzinfo=timezone.utc)


def test_parse_mqtt_payload_json_missing_device_id():
    payload = json.dumps({"level": 1, "message": "test"}).encode()
    event = parse_mqtt_payload("sleepydrive/alerts/jetson-99", payload)
    assert event.device_id == "jetson-99"


def test_parse_mqtt_payload_json_unknown_keys_in_metadata():
    payload = json.dumps({
        "level": 1, "message": "test",
        "custom_field": "custom_value", "count": 42,
    }).encode()
    event = parse_mqtt_payload("topic/device", payload)
    assert event.metadata["custom_field"] == "custom_value"
    assert event.metadata["count"] == 42


def test_parse_mqtt_payload_json_fatigue_risk_promoted():
    payload = json.dumps({
        "level": 1, "message": "test", "fatigue_risk_percent": 75,
    }).encode()
    event = parse_mqtt_payload("topic/device", payload)
    assert event.metadata.get("fatigue_risk_percent") == 75


def test_parse_mqtt_payload_pipe_format():
    event = parse_mqtt_payload("sleepydrive/alerts/dev", b"2|DROWSINESS DETECTED")
    assert event.level == 2
    assert event.message == "DROWSINESS DETECTED"


def test_parse_mqtt_payload_pipe_empty_message():
    event = parse_mqtt_payload("topic/dev", b"1|")
    assert event.level == 1
    assert event.message == "Alert"


def test_parse_mqtt_payload_plain_text():
    event = parse_mqtt_payload("topic/dev", b"Driver falling asleep")
    assert event.level == 1
    assert event.message == "Driver falling asleep"


def test_parse_mqtt_payload_empty_text():
    event = parse_mqtt_payload("topic/dev", b"")
    assert event.level == 1
    assert event.message == "Alert"


# ---------------------------------------------------------------------------
# parse_presence_payload
# ---------------------------------------------------------------------------

def test_parse_presence_payload_type_presence():
    payload = json.dumps({
        "type": "presence", "source_id": "jetson-1", "online": True,
    }).encode()
    presence = parse_presence_payload("sleepydrive/alerts/jetson-1", payload)
    assert presence is not None
    assert presence.source_id == "jetson-1"
    assert presence.online is True


def test_parse_presence_payload_type_heartbeat():
    payload = json.dumps({
        "type": "heartbeat", "source_id": "jetson-1", "online": False,
    }).encode()
    presence = parse_presence_payload("sleepydrive/alerts/jetson-1", payload)
    assert presence is not None
    assert presence.online is True


def test_parse_presence_payload_status_topic():
    payload = json.dumps({"source_id": "jetson-1", "online": True}).encode()
    presence = parse_presence_payload("sleepydrive/status/jetson-1", payload)
    assert presence is not None
    assert presence.online is True


def test_parse_presence_payload_missing_type_wrong_topic():
    payload = json.dumps({"source_id": "jetson-1", "online": True}).encode()
    result = parse_presence_payload("sleepydrive/alerts/jetson-1", payload)
    assert result is None


def test_parse_presence_payload_non_json():
    assert parse_presence_payload("sleepydrive/status/dev", b"2|alert") is None


def test_parse_presence_payload_empty():
    assert parse_presence_payload("sleepydrive/status/dev", b"") is None


def test_parse_presence_payload_unknown_keys_in_metadata():
    payload = json.dumps({
        "type": "presence", "source_id": "jetson-1",
        "online": True, "firmware": "v2.1",
    }).encode()
    presence = parse_presence_payload("sleepydrive/status/jetson-1", payload)
    assert presence is not None
    assert presence.metadata.get("firmware") == "v2.1"


def test_parse_presence_payload_source_id_from_topic():
    payload = json.dumps({"type": "presence", "online": True}).encode()
    presence = parse_presence_payload("sleepydrive/status/my-device", payload)
    assert presence is not None
    assert presence.source_id == "my-device"
