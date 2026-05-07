from __future__ import annotations

import asyncio
from dataclasses import dataclass

import pytest

import mqtt_consumer as mqtt_module
from mqtt_consumer import MQTTConsumer
from schemas import AlertEvent, JetsonPresence


@dataclass
class _Settings:
    mqtt_host: str = "localhost"
    mqtt_port: int = 1883
    mqtt_client_id: str = "test-client"
    mqtt_username: str | None = None
    mqtt_password: str | None = None
    mqtt_topics: tuple[str, ...] = ("sleepydrive/alerts/+",)
    mqtt_qos: int = 1
    mqtt_reconnect_seconds: int = 1
    mqtt_tls_enabled: bool = False
    mqtt_ca_cert: str | None = None
    mqtt_client_cert: str | None = None
    mqtt_client_key: str | None = None
    mqtt_tls_insecure: bool = False
    max_mqtt_payload_bytes: int = 256


class _Repo:
    def __init__(self):
        self.inserted: list[AlertEvent] = []
        self.presence: list[JetsonPresence] = []

    async def insert(self, event: AlertEvent) -> AlertEvent:
        saved = AlertEvent(
            id=101,
            device_id=event.device_id,
            level=event.level,
            message=event.message,
            source=event.source,
            topic=event.topic,
            event_ts=event.event_ts,
            received_ts=event.received_ts,
            metadata=event.metadata,
        )
        self.inserted.append(saved)
        return saved

    async def upsert_presence(self, presence: JetsonPresence) -> None:
        self.presence.append(presence)


@pytest.mark.asyncio
async def test_handle_message_presence_upserts_only():
    repo = _Repo()
    seen_presence = []

    async def on_event(_):
        raise AssertionError("alert callback should not run for presence")

    async def on_presence(presence):
        seen_presence.append(presence)

    consumer = MQTTConsumer(
        settings=_Settings(),
        repository=repo,
        on_event=on_event,
        on_presence=on_presence,
    )

    payload = b'{"type":"presence","source_id":"jetson-1","online":true}'
    await consumer._handle_message("sleepydrive/status/jetson-1", payload)

    assert len(repo.presence) == 1
    assert len(repo.inserted) == 0
    assert len(seen_presence) == 1
    assert seen_presence[0].source_id == "jetson-1"


@pytest.mark.asyncio
async def test_handle_message_alert_inserts_and_notifies():
    repo = _Repo()
    seen_events = []

    async def on_event(event):
        seen_events.append(event)

    consumer = MQTTConsumer(
        settings=_Settings(),
        repository=repo,
        on_event=on_event,
        on_presence=None,
    )

    payload = b'{"device_id":"jetson-2","level":2,"message":"Drowsiness detected"}'
    await consumer._handle_message("sleepydrive/alerts/jetson-2", payload)

    assert len(repo.presence) == 0
    assert len(repo.inserted) == 1
    assert repo.inserted[0].device_id == "jetson-2"
    assert repo.inserted[0].level == 2
    assert len(seen_events) == 1
    assert seen_events[0].id == 101


@pytest.mark.asyncio
async def test_consume_until_error_truncates_payload_before_insert(monkeypatch):
    repo = _Repo()
    saved_events = []

    async def on_event(event):
        saved_events.append(event)

    message_payload = b"2|" + (b"A" * 50)

    class _Message:
        topic = "sleepydrive/alerts/jetson-7"
        payload = message_payload

    class _MessageStream:
        def __init__(self, messages):
            self._messages = iter(messages)

        def __aiter__(self):
            return self

        async def __anext__(self):
            try:
                return next(self._messages)
            except StopIteration:
                raise StopAsyncIteration

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            self.messages = _MessageStream([_Message()])
            self.subscribed = []

        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def subscribe(self, topic, qos):
            self.subscribed.append((topic, qos))

    monkeypatch.setattr(mqtt_module, "Client", _FakeClient)

    settings = _Settings(max_mqtt_payload_bytes=10)
    consumer = MQTTConsumer(
        settings=settings,
        repository=repo,
        on_event=on_event,
        on_presence=None,
    )

    await consumer._consume_until_error(asyncio.Event())

    assert len(repo.inserted) == 1
    assert len(saved_events) == 1
    # Truncated value keeps "2|" plus eight A's.
    assert repo.inserted[0].message == "AAAAAAAA"
