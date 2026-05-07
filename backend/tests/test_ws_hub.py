from __future__ import annotations

from datetime import datetime, timezone

import pytest

from schemas import AlertEvent, JetsonPresence
from ws_hub import WebSocketHub


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _ts():
    return datetime.now(timezone.utc)


def _make_alert(**kwargs) -> AlertEvent:
    defaults = dict(
        device_id="dev", level=1, message="test",
        source="jetson", topic="sleepydrive/alerts/dev",
        event_ts=_ts(), received_ts=_ts(),
    )
    defaults.update(kwargs)
    return AlertEvent(**defaults)


def _make_presence(**kwargs) -> JetsonPresence:
    defaults = dict(
        source_id="dev", online=True,
        event_ts=_ts(), topic="sleepydrive/status/dev",
    )
    defaults.update(kwargs)
    return JetsonPresence(**defaults)


class _MockWebSocket:
    def __init__(self, fail_send: bool = False):
        self.accepted = False
        self.sent: list = []
        self._fail = fail_send

    async def accept(self):
        self.accepted = True

    async def send_json(self, data):
        if self._fail:
            raise RuntimeError("disconnected")
        self.sent.append(data)


# ---------------------------------------------------------------------------
# connect / disconnect
# ---------------------------------------------------------------------------

async def test_connect_accepts_and_adds_client():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    await hub.connect(ws)
    assert ws.accepted is True
    assert ws in hub._clients


async def test_disconnect_removes_client():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    await hub.connect(ws)
    await hub.disconnect(ws)
    assert ws not in hub._clients


async def test_disconnect_noop_if_not_connected():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    await hub.disconnect(ws)  # should not raise


# ---------------------------------------------------------------------------
# send_replay
# ---------------------------------------------------------------------------

async def test_send_replay_sends_events_in_order():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    events = [_make_alert(message=f"msg-{i}") for i in range(3)]
    await hub.send_replay(ws, events)
    assert len(ws.sent) == 3
    for i, msg in enumerate(ws.sent):
        assert msg["type"] == "alert"
        assert msg["data"]["message"] == f"msg-{i}"


# ---------------------------------------------------------------------------
# send_presence_snapshot
# ---------------------------------------------------------------------------

async def test_send_presence_snapshot_sends_all():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    p1 = _make_presence(source_id="dev-1")
    p2 = _make_presence(source_id="dev-2")
    hub._presence_by_source = {"dev-1": p1, "dev-2": p2}
    await hub.send_presence_snapshot(ws)
    assert len(ws.sent) == 2
    types = {m["type"] for m in ws.sent}
    assert types == {"jetson_presence"}
    ids = {m["data"]["source_id"] for m in ws.sent}
    assert ids == {"dev-1", "dev-2"}


# ---------------------------------------------------------------------------
# broadcast_alert
# ---------------------------------------------------------------------------

async def test_broadcast_alert_reaches_all_clients():
    hub = WebSocketHub()
    ws1, ws2 = _MockWebSocket(), _MockWebSocket()
    await hub.connect(ws1)
    await hub.connect(ws2)
    await hub.broadcast_alert(_make_alert(message="fire"))
    assert len(ws1.sent) == 1
    assert ws1.sent[0]["data"]["message"] == "fire"
    assert len(ws2.sent) == 1


async def test_broadcast_alert_no_clients_is_noop():
    hub = WebSocketHub()
    await hub.broadcast_alert(_make_alert())  # should not raise


# ---------------------------------------------------------------------------
# broadcast_presence
# ---------------------------------------------------------------------------

async def test_broadcast_presence_updates_dict():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    await hub.connect(ws)
    p = _make_presence(source_id="dev-1", online=True)
    await hub.broadcast_presence(p)
    assert hub._presence_by_source["dev-1"] is p


async def test_broadcast_presence_overwrites_same_source():
    hub = WebSocketHub()
    ws = _MockWebSocket()
    await hub.connect(ws)
    p1 = _make_presence(source_id="dev-1", online=True)
    p2 = _make_presence(source_id="dev-1", online=False)
    await hub.broadcast_presence(p1)
    await hub.broadcast_presence(p2)
    assert hub._presence_by_source["dev-1"] is p2


# ---------------------------------------------------------------------------
# stale socket cleanup
# ---------------------------------------------------------------------------

async def test_stale_socket_discarded_on_send_error():
    hub = WebSocketHub()
    good = _MockWebSocket()
    bad = _MockWebSocket(fail_send=True)
    await hub.connect(good)
    await hub.connect(bad)
    await hub.broadcast_alert(_make_alert())
    assert bad not in hub._clients
    assert good in hub._clients
