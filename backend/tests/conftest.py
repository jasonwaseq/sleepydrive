import sys
from pathlib import Path

import pytest

BACKEND = Path(__file__).resolve().parents[1]
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))


class FakeAcquire:
    def __init__(self, conn):
        self._conn = conn

    async def __aenter__(self):
        return self._conn

    async def __aexit__(self, exc_type, exc, tb):
        return False


class FakePool:
    def __init__(self, conn):
        self.conn = conn

    def acquire(self):
        return FakeAcquire(self.conn)


class FakeConn:
    def __init__(self):
        self.fetchrow_calls = []
        self.fetch_calls = []
        self.execute_calls = []
        self.fetchrow_handler = None
        self.fetch_handler = None
        self.execute_handler = None

    async def fetchrow(self, query, *args):
        self.fetchrow_calls.append((query, args))
        if self.fetchrow_handler is None:
            return None
        return await self.fetchrow_handler(query, *args)

    async def fetch(self, query, *args):
        self.fetch_calls.append((query, args))
        if self.fetch_handler is None:
            return []
        return await self.fetch_handler(query, *args)

    async def execute(self, query, *args):
        self.execute_calls.append((query, args))
        if self.execute_handler is None:
            return "OK"
        return await self.execute_handler(query, *args)


@pytest.fixture()
def stable_env(monkeypatch):
    monkeypatch.setenv("JWT_SECRET", "test-jwt-secret")
    monkeypatch.setenv("GATEWAY_API_KEY", "test-gateway-key")
    monkeypatch.setenv("DATABASE_URL", "postgresql://test/test")
    monkeypatch.setenv("MQTT_HOST", "localhost")
    monkeypatch.setenv("MQTT_PORT", "1883")
    monkeypatch.setenv("MQTT_TOPICS", "sleepydrive/alerts/+")
