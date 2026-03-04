from __future__ import annotations

import asyncpg


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
    def __init__(self, dsn: str, min_size: int = 1, max_size: int = 10):
        self._dsn = dsn
        self._min_size = min_size
        self._max_size = max_size
        self._pool: asyncpg.Pool | None = None

    @property
    def pool(self) -> asyncpg.Pool:
        if self._pool is None:
            raise RuntimeError("Database pool not initialized")
        return self._pool

    async def connect(self) -> None:
        self._pool = await asyncpg.create_pool(
            dsn=self._dsn,
            min_size=self._min_size,
            max_size=self._max_size,
        )

    async def init_schema(self) -> None:
        async with self.pool.acquire() as conn:
            await conn.execute(SCHEMA_SQL)

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

