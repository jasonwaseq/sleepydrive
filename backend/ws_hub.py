from __future__ import annotations

import asyncio
from typing import Iterable

from fastapi import WebSocket

from schemas import AlertEvent, JetsonPresence


class WebSocketHub:
    def __init__(self):
        self._clients: set[WebSocket] = set()
        self._lock = asyncio.Lock()
        self._presence_by_source: dict[str, JetsonPresence] = {}

    async def connect(self, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._clients.add(websocket)

    async def disconnect(self, websocket: WebSocket) -> None:
        async with self._lock:
            self._clients.discard(websocket)

    async def send_replay(self, websocket: WebSocket, events: Iterable[AlertEvent]) -> None:
        for event in events:
            await websocket.send_json({"type": "alert", "data": event.as_dict()})

    async def send_presence_snapshot(self, websocket: WebSocket) -> None:
        async with self._lock:
            presence_list = list(self._presence_by_source.values())
        for presence in presence_list:
            await websocket.send_json({"type": "jetson_presence", "data": presence.as_dict()})

    async def broadcast_alert(self, event: AlertEvent) -> None:
        await self._broadcast_payload({"type": "alert", "data": event.as_dict()})

    async def broadcast_presence(self, presence: JetsonPresence) -> None:
        async with self._lock:
            self._presence_by_source[presence.source_id] = presence
        await self._broadcast_payload({"type": "jetson_presence", "data": presence.as_dict()})

    async def _broadcast_payload(self, payload: dict) -> None:
        async with self._lock:
            clients = list(self._clients)

        if not clients:
            return

        async def send_one(websocket: WebSocket) -> WebSocket | None:
            try:
                await websocket.send_json(payload)
            except Exception:
                return websocket
            return None

        results = await asyncio.gather(*(send_one(ws) for ws in clients))
        stale = [ws for ws in results if ws is not None]

        if stale:
            async with self._lock:
                for websocket in stale:
                    self._clients.discard(websocket)
