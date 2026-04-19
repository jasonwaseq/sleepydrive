from __future__ import annotations

import ssl
from urllib.parse import urlparse

import asyncpg


def _ssl_context_for_dsn(dsn: str) -> ssl.SSLContext | None:
    """Use TLS for Neon and other hosts that require encrypted Postgres."""

    lowered = dsn.lower()
    if "sslmode=disable" in lowered:
        return None
    if "sslmode=require" in lowered or "sslmode=verify-full" in lowered or "sslmode=verify-ca" in lowered:
        return ssl.create_default_context()
    try:
        host = (urlparse(dsn).hostname or "").lower()
    except Exception:
        host = ""
    if host.endswith(".neon.tech") or host.endswith(".neon.build"):
        return ssl.create_default_context()
    return None


USERS_SQL = """
CREATE TABLE IF NOT EXISTS users (
    uid TEXT PRIMARY KEY,
    role TEXT NOT NULL CHECK (role IN ('driver', 'operator'))
);
"""

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS alert_events (
    id BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL,
    level SMALLINT NOT NULL CHECK (level >= 0 AND level <= 2),
    message TEXT NOT NULL,
    source TEXT NOT NULL,
    topic TEXT NOT NULL,
    event_ts TIMESTAMPTZ NOT NULL,
    received_ts TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    metadata JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_alert_events_received_ts
ON alert_events (received_ts DESC);

CREATE INDEX IF NOT EXISTS idx_alert_events_device_received
ON alert_events (device_id, received_ts DESC);
"""


class Database:
    def __init__(
        self,
        dsn: str,
        min_size: int = 1,
        max_size: int = 10,
        command_timeout: float | None = None,
    ):
        self._dsn = dsn
        self._min_size = min_size
        self._max_size = max_size
        self._command_timeout = command_timeout
        self._pool: asyncpg.Pool | None = None

    @property
    def pool(self) -> asyncpg.Pool:
        if self._pool is None:
            raise RuntimeError("Database pool not initialized")
        return self._pool

    async def connect(self) -> None:
        ssl_ctx = _ssl_context_for_dsn(self._dsn)
        kwargs: dict = {
            "dsn": self._dsn,
            "min_size": self._min_size,
            "max_size": self._max_size,
            "max_inactive_connection_lifetime": 300.0,
        }
        if ssl_ctx is not None:
            kwargs["ssl"] = ssl_ctx
        if self._command_timeout is not None:
            kwargs["command_timeout"] = self._command_timeout
        self._pool = await asyncpg.create_pool(**kwargs)

    async def init_schema(self) -> None:
        async with self.pool.acquire() as conn:
            await conn.execute(SCHEMA_SQL)
            await conn.execute(USERS_SQL)

    async def ping(self) -> None:
        async with self.pool.acquire() as conn:
            await conn.fetchval("SELECT 1")

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

