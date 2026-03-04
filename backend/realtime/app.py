from __future__ import annotations

import asyncio
import contextlib
import logging
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from db import Database
from mqtt_consumer import MQTTConsumer
from repository import AlertRepository
from settings import Settings
from ws_hub import WebSocketHub

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
log = logging.getLogger("realtime.app")

if sys.platform.startswith("win"):
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


def create_app() -> FastAPI:
    settings = Settings.from_env()
    db = Database(settings.database_url)
    repo = AlertRepository(db)
    hub = WebSocketHub()
    stop_event = asyncio.Event()
    consumer = MQTTConsumer(settings=settings, repository=repo, on_event=hub.broadcast_alert)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await db.connect()
        await db.init_schema()
        log.info("Database connected and schema initialized")

        consumer_task = asyncio.create_task(consumer.run(stop_event), name="mqtt-consumer")
        app.state.settings = settings
        app.state.repo = repo
        app.state.hub = hub
        app.state.consumer_task = consumer_task

        try:
            yield
        finally:
            stop_event.set()
            consumer_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await consumer_task
            await db.close()
            log.info("Realtime gateway shut down cleanly")

    app = FastAPI(
        title="SleepyDrive Realtime Gateway",
        version="0.1.0",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(settings.cors_allow_origins),
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/alerts/recent")
    async def recent_alerts(
        limit: int = Query(default=25, ge=1, le=500),
        device_id: str | None = None,
    ) -> dict[str, object]:
        events = await repo.recent(limit=limit, device_id=device_id)
        return {"count": len(events), "items": [event.as_dict() for event in events]}

    @app.websocket("/ws/alerts")
    async def ws_alerts(
        websocket: WebSocket,
        replay: int = Query(default=-1, ge=-1, le=500),
    ) -> None:
        await hub.connect(websocket)
        try:
            replay_count = settings.ws_default_replay if replay < 0 else replay
            if replay_count > 0:
                events = await repo.recent(limit=replay_count)
                await hub.send_replay(websocket=websocket, events=reversed(events))

            # Keep socket open; clients can optionally send pings.
            while True:
                await websocket.receive_text()
        except WebSocketDisconnect:
            pass
        finally:
            await hub.disconnect(websocket)

    return app


app = create_app()
