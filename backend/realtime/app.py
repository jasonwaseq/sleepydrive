from __future__ import annotations

import asyncio
import contextlib
import logging
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from db import Database
from mqtt_consumer import MQTTConsumer
from repository import AlertRepository
from security import SecurityHeadersMiddleware, gateway_key_matches
from settings import Settings
from ws_hub import WebSocketHub

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
log = logging.getLogger("realtime.app")


def _check_gateway_rest(
    settings: Settings,
    x_api_key: str | None,
    authorization: str | None,
) -> None:
    key = settings.gateway_api_key
    if not key:
        return
    bearer = authorization[7:].strip() if authorization and authorization.startswith("Bearer ") else None
    if x_api_key and gateway_key_matches(x_api_key, key):
        return
    if bearer and gateway_key_matches(bearer, key):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")


def _log_security_warnings(settings: Settings) -> None:
    if settings.gateway_api_key is None:
        log.warning(
            "GATEWAY_API_KEY is not set: /alerts/recent and /ws/alerts are unauthenticated",
        )
    host = settings.mqtt_host.lower()
    if host not in {"127.0.0.1", "localhost", "::1"} and not settings.mqtt_tls_enabled:
        log.warning(
            "MQTT_TLS is disabled while MQTT_HOST=%s — enable TLS for production",
            settings.mqtt_host,
        )
    if settings.mqtt_tls_insecure:
        log.warning("MQTT_TLS_INSECURE is enabled: server certificate verification is off")


def _validate_device_query(device_id: str | None) -> str | None:
    if device_id is None:
        return None
    cleaned = device_id.strip()
    if "\x00" in cleaned or len(cleaned) > 256:
        raise HTTPException(status_code=400, detail="Invalid device_id")
    return cleaned


async def _receive_within_limit(websocket: WebSocket, max_bytes: int) -> None:
    message = await websocket.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect()
    if message["type"] != "websocket.receive":
        return
    text = message.get("text")
    if text is not None and len(text.encode("utf-8")) > max_bytes:
        await websocket.close(code=1009)
        raise WebSocketDisconnect()
    data = message.get("bytes")
    if data is not None and len(data) > max_bytes:
        await websocket.close(code=1009)
        raise WebSocketDisconnect()


if sys.platform.startswith("win"):
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())


def create_app() -> FastAPI:
    settings = Settings.from_env()
    db = Database(settings.database_url, command_timeout=settings.db_command_timeout_seconds)
    repo = AlertRepository(db)
    hub = WebSocketHub()
    stop_event = asyncio.Event()
    consumer = MQTTConsumer(
        settings=settings,
        repository=repo,
        on_event=hub.broadcast_alert,
        on_presence=hub.broadcast_presence,
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        await db.connect()
        await db.init_schema()
        log.info("Database connected and schema initialized")
        _log_security_warnings(settings)

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

    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(
        TrustedHostMiddleware,
        allowed_hosts=list(settings.trusted_hosts),
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

    @app.get("/readyz")
    async def readyz() -> dict[str, str]:
        try:
            await db.ping()
        except Exception:
            log.exception("Readiness check failed")
            raise HTTPException(status_code=503, detail="database_unavailable") from None
        return {"status": "ready"}

    @app.get("/alerts/recent")
    async def recent_alerts(
        limit: int = Query(default=25, ge=1, le=500),
        device_id: str | None = None,
        x_api_key: str | None = Header(None, alias="X-API-Key"),
        authorization: str | None = Header(None),
    ) -> dict[str, object]:
        _check_gateway_rest(settings, x_api_key, authorization)
        device_id = _validate_device_query(device_id)
        events = await repo.recent(limit=limit, device_id=device_id)
        return {"count": len(events), "items": [event.as_dict() for event in events]}

    @app.post("/users")
    async def create_user(data: dict) -> dict[str, str]:
        uid = data.get("uid")
        role = data.get("role")

        if not uid or not role:
            raise HTTPException(status_code=400, detail="Missing uid or role")

        if role not in {"driver", "operator"}:
            raise HTTPException(status_code=400, detail="Invalid role")

        async with db.pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO users (uid, role)
                VALUES ($1, $2)
                ON CONFLICT (uid) DO UPDATE SET role = EXCLUDED.role
                """,
                uid,
                role,
            )

        return {"status": "ok"}

    @app.get("/users/{uid}")
    async def get_user(uid: str) -> dict[str, str]:
        async with db.pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT uid, role FROM users WHERE uid = $1",
                uid,
            )

        if row is None:
            raise HTTPException(status_code=404, detail="User not found")

        return {"uid": row["uid"], "role": row["role"]}

    @app.websocket("/ws/alerts")
    async def ws_alerts(
        websocket: WebSocket,
        replay: int = Query(default=-1, ge=-1, le=500),
        token: str | None = Query(None),
    ) -> None:
        if settings.gateway_api_key and not gateway_key_matches(token, settings.gateway_api_key):
            await websocket.close(code=1008)
            return
        await hub.connect(websocket)
        try:
            replay_count = settings.ws_default_replay if replay < 0 else replay
            if replay_count > 0:
                events = await repo.recent(limit=replay_count)
                await hub.send_replay(websocket=websocket, events=reversed(events))
            await hub.send_presence_snapshot(websocket=websocket)

            idle = settings.ws_idle_ping_seconds
            max_in = settings.ws_max_incoming_bytes
            while True:
                if idle > 0:
                    try:
                        await asyncio.wait_for(
                            _receive_within_limit(websocket, max_in),
                            timeout=float(idle),
                        )
                    except asyncio.TimeoutError:
                        await websocket.send_json({"type": "ping"})
                else:
                    await _receive_within_limit(websocket, max_in)
        except WebSocketDisconnect:
            pass
        finally:
            await hub.disconnect(websocket)

    return app


app = create_app()
