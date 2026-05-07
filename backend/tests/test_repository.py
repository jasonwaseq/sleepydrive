from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import asyncpg
import pytest

from repository import AlertRepository
from schemas import AlertEvent, JetsonPresence
from tests.conftest import FakeConn


class _FakeDb:
    def __init__(self, conn):
        self.pool = conn


def _event() -> AlertEvent:
    return AlertEvent(
        device_id="dev-1",
        level=2,
        message="danger",
        source="jetson",
        topic="sleepydrive/alerts/dev-1",
        event_ts=datetime(2025, 1, 2, tzinfo=timezone.utc),
        received_ts=datetime(2025, 1, 2, tzinfo=timezone.utc),
        metadata={"fatigue_risk_percent": 88, "extra": "x"},
    )


@pytest.mark.asyncio
async def test_insert_serializes_metadata_and_maps_db_response():
    conn = FakeConn()
    repo = AlertRepository(_FakeDb(conn))
    ts = datetime(2025, 1, 2, 12, 0, tzinfo=timezone.utc)

    async def fetchrow_handler(query, *args):
        assert "INSERT INTO alert_events" in query
        assert args[0] == "dev-1"
        assert args[1] == 2
        assert args[2] == "danger"
        assert args[3] == "jetson"
        assert args[4] == "sleepydrive/alerts/dev-1"
        assert args[7] == '{"fatigue_risk_percent":88,"extra":"x"}'
        return {"id": 77, "received_ts": ts}

    conn.fetchrow_handler = fetchrow_handler

    saved = await repo.insert(_event())

    assert saved.id == 77
    assert saved.received_ts == ts
    assert saved.metadata["fatigue_risk_percent"] == 88


@pytest.mark.asyncio
async def test_insert_retries_transient_failures(monkeypatch):
    conn = FakeConn()
    repo = AlertRepository(_FakeDb(conn))
    calls = {"n": 0}

    async def fetchrow_handler(_query, *_args):
        calls["n"] += 1
        if calls["n"] == 1:
            raise asyncpg.exceptions.InterfaceError("temporary")
        return {"id": 99, "received_ts": datetime.now(timezone.utc)}

    async def no_sleep(_):
        return None

    conn.fetchrow_handler = fetchrow_handler
    monkeypatch.setattr(asyncio, "sleep", no_sleep)

    saved = await repo.insert(_event())
    assert saved.id == 99
    assert calls["n"] == 2


@pytest.mark.asyncio
async def test_insert_raises_after_retry_exhaustion(monkeypatch):
    conn = FakeConn()
    repo = AlertRepository(_FakeDb(conn))
    calls = {"n": 0}

    async def fetchrow_handler(_query, *_args):
        calls["n"] += 1
        raise asyncpg.exceptions.ConnectionDoesNotExistError("down")

    async def no_sleep(_):
        return None

    conn.fetchrow_handler = fetchrow_handler
    monkeypatch.setattr(asyncio, "sleep", no_sleep)

    with pytest.raises(asyncpg.exceptions.ConnectionDoesNotExistError):
        await repo.insert(_event())
    assert calls["n"] == 3


@pytest.mark.asyncio
async def test_upsert_presence_serializes_metadata():
    conn = FakeConn()
    repo = AlertRepository(_FakeDb(conn))
    presence = JetsonPresence(
        source_id="jetson-1",
        online=True,
        event_ts=datetime(2025, 1, 2, tzinfo=timezone.utc),
        topic="sleepydrive/status/jetson-1",
        source="jetson",
        metadata={"firmware": "2.0"},
    )

    await repo.upsert_presence(presence)

    assert len(conn.execute_calls) == 1
    query, args = conn.execute_calls[0]
    assert "INSERT INTO device_status" in query
    assert args[0] == "jetson-1"
    assert args[1] is True
    assert args[5] == '{"firmware":"2.0"}'
