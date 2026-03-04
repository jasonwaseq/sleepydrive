from __future__ import annotations

import asyncio
from typing import Iterable

from fastapi import WebSocket

from schemas import AlertEvent


class WebSocketHub:
    def __init__(self):
        self._clients: set[WebSocket] = set()
        self._lock = asyncio.Lock()

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

    async def broadcast_alert(self, event: AlertEvent) -> None:
        payload = {"type": "alert", "data": event.as_dict()}
        async with self._lock:
            clients = list(self._clients)

        if not clients:
            return

        stale: list[WebSocket] = []
        for websocket in clients:
            try:
                await websocket.send_json(payload)
            except Exception:
                stale.append(websocket)

        if stale:
            async with self._lock:
                for websocket in stale:
                    self._clients.discard(websocket)

