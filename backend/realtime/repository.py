from __future__ import annotations

import json
from typing import Any

from db import Database
from schemas import AlertEvent


class AlertRepository:
    def __init__(self, db: Database):
        self._db = db

    async def insert(self, event: AlertEvent) -> AlertEvent:
        row = await self._db.pool.fetchrow(
            """
            INSERT INTO alert_events (
                device_id,
                level,
                message,
                source,
                topic,
                event_ts,
                received_ts,
                metadata
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)
            RETURNING id, received_ts
            """,
            event.device_id,
            event.level,
            event.message,
            event.source,
            event.topic,
            event.event_ts,
            event.received_ts,
            json.dumps(event.metadata),
        )
        return AlertEvent(
            id=row["id"],
            device_id=event.device_id,
            level=event.level,
            message=event.message,
            source=event.source,
            topic=event.topic,
            event_ts=event.event_ts,
            received_ts=row["received_ts"],
            metadata=event.metadata,
        )

    async def recent(self, limit: int = 25, device_id: str | None = None) -> list[AlertEvent]:
        safe_limit = max(1, min(limit, 500))
        if device_id:
            rows = await self._db.pool.fetch(
                """
                SELECT id, device_id, level, message, source, topic, event_ts, received_ts, metadata
                FROM alert_events
                WHERE device_id = $1
                ORDER BY received_ts DESC
                LIMIT $2
                """,
                device_id,
                safe_limit,
            )
        else:
            rows = await self._db.pool.fetch(
                """
                SELECT id, device_id, level, message, source, topic, event_ts, received_ts, metadata
                FROM alert_events
                ORDER BY received_ts DESC
                LIMIT $1
                """,
                safe_limit,
            )
        return [self._row_to_event(row) for row in rows]

    @staticmethod
    def _row_to_event(row: Any) -> AlertEvent:
        metadata = row["metadata"] if isinstance(row["metadata"], dict) else {}
        return AlertEvent(
            id=row["id"],
            device_id=row["device_id"],
            level=row["level"],
            message=row["message"],
            source=row["source"],
            topic=row["topic"],
            event_ts=row["event_ts"],
            received_ts=row["received_ts"],
            metadata=metadata,
        )

