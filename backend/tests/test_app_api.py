from __future__ import annotations

from datetime import datetime, timezone

import bcrypt as _bcrypt
import pytest
from fastapi.testclient import TestClient

import app as app_module
from tests.conftest import FakeConn, FakePool
from schemas import AlertEvent


@pytest.fixture()
def api_harness(stable_env, monkeypatch):
    conn = FakeConn()
    credentials: dict[str, dict[str, str]] = {}

    async def fetchrow_handler(query, *args):
        if "SELECT uid, password_hash FROM credentials" in query:
            return credentials.get(args[0])
        return None

    async def execute_handler(query, *args):
        if "INSERT INTO credentials" in query:
            uid, email, password_hash = args
            if email in credentials:
                raise Exception("unique violation")
            credentials[email] = {"uid": uid, "password_hash": password_hash}
            return "INSERT 0 1"
        return "OK"

    conn.fetchrow_handler = fetchrow_handler
    conn.execute_handler = execute_handler

    class FakeDatabase:
        def __init__(self, dsn, command_timeout=None):
            self.pool = FakePool(conn)
            self.connected = False
            self.schema_ready = False
            self.closed = False

        async def connect(self):
            self.connected = True

        async def init_schema(self):
            self.schema_ready = True

        async def ping(self):
            return None

        async def close(self):
            self.closed = True

    class FakeRepo:
        def __init__(self, db):
            self.recent_calls: list[tuple[int, str | None]] = []
            self._events = [
                AlertEvent(
                    id=1,
                    device_id="dev-1",
                    level=2,
                    message="Drowsiness detected",
                    source="jetson",
                    topic="sleepydrive/alerts/dev-1",
                    event_ts=datetime(2025, 1, 1, tzinfo=timezone.utc),
                    received_ts=datetime(2025, 1, 1, tzinfo=timezone.utc),
                    metadata={"fatigue_risk_percent": 92},
                ),
            ]

        async def recent(self, limit=25, device_id=None):
            self.recent_calls.append((limit, device_id))
            return self._events[:limit]

    class FakeMQTTConsumer:
        def __init__(self, settings, repository, on_event, on_presence):
            pass

        async def run(self, stop_event):
            await stop_event.wait()

    monkeypatch.setattr(app_module, "Database", FakeDatabase)
    monkeypatch.setattr(app_module, "AlertRepository", FakeRepo)
    monkeypatch.setattr(app_module, "MQTTConsumer", FakeMQTTConsumer)

    app = app_module.create_app()
    with TestClient(app) as client:
        yield {
            "client": client,
            "credentials": credentials,
            "app": app,
            "conn": conn,
        }


def test_signup_creates_credential_row_and_returns_token(api_harness):
    resp = api_harness["client"].post(
        "/auth/signup",
        json={"email": "Driver@Example.com", "password": "secret123"},
    )

    assert resp.status_code == 201
    body = resp.json()
    assert body["email"] == "driver@example.com"
    assert body["uid"]
    assert body["token"]
    assert "driver@example.com" in api_harness["credentials"]


def test_signup_rejects_invalid_payload(api_harness):
    resp = api_harness["client"].post(
        "/auth/signup",
        json={"email": "driver@example.com", "password": "123"},
    )
    assert resp.status_code == 400


def test_signup_duplicate_email_returns_409(api_harness):
    payload = {"email": "driver@example.com", "password": "secret123"}
    first = api_harness["client"].post("/auth/signup", json=payload)
    second = api_harness["client"].post("/auth/signup", json=payload)

    assert first.status_code == 201
    assert second.status_code == 409
    assert second.json()["detail"] == "email-already-in-use"


def test_login_authenticates_valid_credentials(api_harness):
    api_harness["credentials"]["driver@example.com"] = {
        "uid": "driver-1",
        "password_hash": _bcrypt.hashpw(b"secret123", _bcrypt.gensalt()).decode(),
    }

    resp = api_harness["client"].post(
        "/auth/login",
        json={"email": "driver@example.com", "password": "secret123"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["uid"] == "driver-1"
    assert body["email"] == "driver@example.com"
    assert body["token"]


def test_login_rejects_wrong_password(api_harness):
    api_harness["credentials"]["driver@example.com"] = {
        "uid": "driver-1",
        "password_hash": _bcrypt.hashpw(b"secret123", _bcrypt.gensalt()).decode(),
    }

    resp = api_harness["client"].post(
        "/auth/login",
        json={"email": "driver@example.com", "password": "wrong"},
    )

    assert resp.status_code == 401
    assert resp.json()["detail"] == "wrong-password"


def test_login_rejects_missing_fields(api_harness):
    resp = api_harness["client"].post("/auth/login", json={"email": "driver@example.com"})
    assert resp.status_code == 400


def test_alerts_recent_requires_gateway_auth(api_harness):
    resp = api_harness["client"].get("/alerts/recent")
    assert resp.status_code == 401


def test_alerts_recent_accepts_x_api_key_and_returns_items(api_harness):
    resp = api_harness["client"].get(
        "/alerts/recent",
        params={"limit": 10, "device_id": " dev-1 "},
        headers={"X-API-Key": "test-gateway-key"},
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["count"] == 1
    assert body["items"][0]["device_id"] == "dev-1"
    assert api_harness["app"].state.repo.recent_calls[-1] == (10, "dev-1")


def test_alerts_recent_accepts_bearer_gateway_token(api_harness):
    resp = api_harness["client"].get(
        "/alerts/recent",
        headers={"Authorization": "Bearer test-gateway-key"},
    )
    assert resp.status_code == 200


def test_alerts_recent_rejects_invalid_device_id(api_harness):
    resp = api_harness["client"].get(
        "/alerts/recent",
        params={"device_id": "bad\u0000id"},
        headers={"X-API-Key": "test-gateway-key"},
    )
    assert resp.status_code == 400
