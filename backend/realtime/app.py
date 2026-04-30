from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import asynccontextmanager
from typing import Any
from fastapi import FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from auth import AuthUser, require_firebase_user
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


def _clean_optional_text(value: Any, max_chars: int = 256) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    return text[:max_chars]


def _normalize_invite_code(value: Any) -> str | None:
    text = _clean_optional_text(value, 64)
    if text is None:
        return None
    return text.replace(" ", "").replace("-", "").upper()


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return value.isoformat()
    return str(value)


def _coerce_percent(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        parsed = float(str(value).strip().rstrip("%"))
    except (TypeError, ValueError):
        return None
    if parsed < 0:
        return 0
    if 0 < parsed <= 1:
        parsed *= 100
    return max(0, min(round(parsed), 100))


def _metadata_percent(metadata: Any) -> int | None:
    if not isinstance(metadata, dict):
        return None
    for key in (
        "fatigue_risk_percent",
        "fatigue_risk",
        "fatigueRiskPercent",
        "fatigueRisk",
        "risk_percent",
        "riskPercent",
        "fatigue_score",
        "fatigueScore",
        "score",
    ):
        value = _coerce_percent(metadata.get(key))
        if value is not None:
            return value
    risk = _coerce_percent(metadata.get("risk"))
    if risk is not None and risk > 2:
        return risk
    return None


def _fetch_json_url(url: str, timeout_seconds: float = 12.0) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "SleepyDrive/1.0 routing-proxy",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            status = getattr(response, "status", response.getcode())
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise HTTPException(
            status_code=502,
            detail=f"Routing provider returned HTTP {exc.code}: {detail}",
        ) from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Routing provider unavailable: {exc}",
        ) from exc

    if status != 200:
        raise HTTPException(
            status_code=502,
            detail=f"Routing provider returned HTTP {status}",
        )

    try:
        data = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=502, detail="Routing provider returned invalid JSON") from exc

    if not isinstance(data, dict):
        raise HTTPException(status_code=502, detail="Routing provider response was invalid")
    return data


def _decode_google_polyline(polyline: str) -> list[list[float]]:
    coords: list[list[float]] = []
    index = 0
    lat = 0
    lng = 0

    while index < len(polyline):
        result = 0
        shift = 0
        while True:
            value = ord(polyline[index]) - 63
            index += 1
            result |= (value & 0x1F) << shift
            shift += 5
            if value < 0x20:
                break
        lat += ~(result >> 1) if result & 1 else result >> 1

        result = 0
        shift = 0
        while True:
            value = ord(polyline[index]) - 63
            index += 1
            result |= (value & 0x1F) << shift
            shift += 5
            if value < 0x20:
                break
        lng += ~(result >> 1) if result & 1 else result >> 1

        coords.append([lng / 1e5, lat / 1e5])

    return coords


def _google_directions_to_osrm(data: dict[str, Any]) -> dict[str, Any]:
    status = str(data.get("status") or "UNKNOWN")
    if status != "OK":
        detail = str(data.get("error_message") or status)
        raise HTTPException(status_code=502, detail=f"Google Directions error {detail}")

    routes = data.get("routes")
    if not isinstance(routes, list) or not routes:
        raise HTTPException(status_code=502, detail="Google Directions returned no routes")

    route = routes[0]
    if not isinstance(route, dict):
        raise HTTPException(status_code=502, detail="Google Directions route was invalid")

    legs = route.get("legs")
    if not isinstance(legs, list) or not legs:
        raise HTTPException(status_code=502, detail="Google Directions returned no legs")

    distance = 0.0
    duration = 0.0
    for leg in legs:
        if not isinstance(leg, dict):
            continue
        distance += float((leg.get("distance") or {}).get("value") or 0)
        duration += float((leg.get("duration") or {}).get("value") or 0)

    overview = route.get("overview_polyline")
    points = overview.get("points") if isinstance(overview, dict) else None
    if not isinstance(points, str) or not points:
        raise HTTPException(status_code=502, detail="Google Directions returned no route geometry")

    return {
        "code": "Ok",
        "routes": [
            {
                "distance": distance,
                "duration": duration,
                "geometry": {
                    "type": "LineString",
                    "coordinates": _decode_google_polyline(points),
                },
            },
        ],
    }


def _risk_from_alert_level(level: Any) -> int | None:
    try:
        parsed = int(level)
    except (TypeError, ValueError):
        return None
    if parsed <= 0:
        return 0
    if parsed == 1:
        return 50
    return 90


def _fatigue_status(risk: int | None) -> str:
    if risk is None:
        return "No data"
    if risk >= 90:
        return "Extreme fatigue"
    if risk >= 70:
        return "Critical fatigue"
    if risk >= 50:
        return "High fatigue"
    if risk >= 30:
        return "Moderate fatigue"
    if risk >= 10:
        return "Low fatigue"
    return "No fatigue"


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

    def _auth_user(authorization: str | None) -> AuthUser:
        return require_firebase_user(
            authorization=authorization,
            project_id=settings.firebase_project_id,
        )

    @app.get("/routing/driving")
    async def driving_route(
        from_lat: float = Query(..., ge=-90, le=90),
        from_lon: float = Query(..., ge=-180, le=180),
        to_lat: float = Query(..., ge=-90, le=90),
        to_lon: float = Query(..., ge=-180, le=180),
        google_api_key: str | None = Query(None, max_length=256),
    ):
        query = urllib.parse.urlencode(
            {
                "overview": "full",
                "geometries": "geojson",
            },
        )
        route_path = f"{from_lon},{from_lat};{to_lon},{to_lat}?{query}"
        urls = (
            f"https://router.project-osrm.org/route/v1/driving/{route_path}",
            f"https://routing.openstreetmap.de/routed-car/route/v1/driving/{route_path}",
        )
        errors = []
        for url in urls:
            try:
                return await asyncio.to_thread(_fetch_json_url, url)
            except HTTPException as exc:
                errors.append(str(exc.detail))

        google_key = (
            google_api_key
            or os.getenv("GOOGLE_DIRECTIONS_API_KEY")
            or os.getenv("GOOGLE_MAPS_API_KEY")
            or os.getenv("GOOGLE_PLACES_API_KEY")
        )
        if google_key:
            google_query = urllib.parse.urlencode(
                {
                    "origin": f"{from_lat},{from_lon}",
                    "destination": f"{to_lat},{to_lon}",
                    "mode": "driving",
                    "key": google_key,
                },
            )
            try:
                data = await asyncio.to_thread(
                    _fetch_json_url,
                    f"https://maps.googleapis.com/maps/api/directions/json?{google_query}",
                )
                return _google_directions_to_osrm(data)
            except HTTPException as exc:
                errors.append(str(exc.detail))

        raise HTTPException(status_code=502, detail=" | ".join(errors))

    async def _generate_invite_code(conn) -> str:
        alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        for _ in range(12):
            code = "".join(secrets.choice(alphabet) for _ in range(8))
            exists = await conn.fetchval(
                "SELECT 1 FROM fleets WHERE invite_code = $1",
                code,
            )
            if not exists:
                return code
        raise HTTPException(status_code=500, detail="Could not generate invite code")

    async def _ensure_operator_fleet(conn, user: AuthUser, existing_fleet_id: str | None):
        if existing_fleet_id:
            fleet = await conn.fetchrow(
                "SELECT id, name, owner_uid, invite_code FROM fleets WHERE id = $1",
                existing_fleet_id,
            )
            if fleet is not None:
                return fleet

        fleet = await conn.fetchrow(
            "SELECT id, name, owner_uid, invite_code FROM fleets WHERE owner_uid = $1",
            user.uid,
        )
        if fleet is not None:
            return fleet

        fleet_id = str(uuid.uuid4())
        invite_code = await _generate_invite_code(conn)
        base_name = user.name or user.email or "SleepyDrive"
        fleet_name = f"{base_name.split('@')[0]}'s Fleet"
        return await conn.fetchrow(
            """
            INSERT INTO fleets (id, name, owner_uid, invite_code)
            VALUES ($1, $2, $3, $4)
            RETURNING id, name, owner_uid, invite_code
            """,
            fleet_id,
            fleet_name[:256],
            user.uid,
            invite_code,
        )

    async def _profile_row(uid: str):
        async with db.pool.acquire() as conn:
            return await conn.fetchrow(
                """
                SELECT
                    u.uid,
                    u.role,
                    u.email,
                    u.display_name,
                    u.fleet_id,
                    u.device_id,
                    f.name AS fleet_name,
                    f.invite_code AS fleet_invite_code
                FROM users u
                LEFT JOIN fleets f ON f.id = u.fleet_id
                WHERE u.uid = $1
                """,
                uid,
            )

    def _profile_response(row) -> dict[str, Any]:
        return {
            "uid": row["uid"],
            "role": row["role"],
            "email": row["email"],
            "display_name": row["display_name"],
            "fleet_id": row["fleet_id"],
            "device_id": row["device_id"],
            "fleet_name": row["fleet_name"],
            "fleet_invite_code": row["fleet_invite_code"],
        }

    async def _require_current_profile(user: AuthUser) -> Any:
        row = await _profile_row(user.uid)
        if row is None:
            raise HTTPException(status_code=404, detail="User profile not found")
        return row

    async def _require_operator_profile(user: AuthUser) -> Any:
        row = await _require_current_profile(user)
        if row["role"] != "operator":
            raise HTTPException(status_code=403, detail="Fleet operator role required")
        if not row["fleet_id"]:
            async with db.pool.acquire() as conn:
                fleet = await _ensure_operator_fleet(conn, user, None)
                await conn.execute(
                    """
                    UPDATE users
                    SET fleet_id = $2, updated_at = NOW()
                    WHERE uid = $1
                    """,
                    user.uid,
                    fleet["id"],
                )
            row = await _profile_row(user.uid)
        return row

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
    async def create_user(
        data: dict,
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        user = _auth_user(authorization)
        uid = _clean_optional_text(data.get("uid"), 256) or user.uid
        role = _clean_optional_text(data.get("role"), 32)

        if uid != user.uid:
            raise HTTPException(status_code=403, detail="Cannot edit another user profile")

        if not role:
            raise HTTPException(status_code=400, detail="Missing uid or role")

        if role not in {"driver", "operator"}:
            raise HTTPException(status_code=400, detail="Invalid role")

        async with db.pool.acquire() as conn:
            existing = await conn.fetchrow(
                "SELECT role, fleet_id, device_id FROM users WHERE uid = $1",
                user.uid,
            )

            if existing is not None and existing["role"] != role:
                raise HTTPException(status_code=409, detail="Cannot change role once set")

            email = _clean_optional_text(data.get("email") or user.email, 320)
            display_name = _clean_optional_text(
                data.get("display_name") or user.name or email,
                256,
            )
            requested_device_id = _clean_optional_text(data.get("device_id"), 256)
            device_id = requested_device_id
            if role == "driver" and device_id is None and existing is not None:
                device_id = existing["device_id"]
            if role == "driver" and device_id is None:
                device_id = user.uid

            fleet_id = existing["fleet_id"] if existing is not None else None

            if role == "driver":
                invite_code = _normalize_invite_code(data.get("fleet_invite_code"))
                if invite_code:
                    fleet = await conn.fetchrow(
                        "SELECT id FROM fleets WHERE invite_code = $1",
                        invite_code,
                    )
                    if fleet is None:
                        raise HTTPException(status_code=404, detail="Fleet invite code not found")
                    fleet_id = fleet["id"]
            else:
                fleet = await _ensure_operator_fleet(conn, user, fleet_id)
                fleet_id = fleet["id"]

            await conn.execute(
                """
                INSERT INTO users (
                    uid,
                    role,
                    email,
                    display_name,
                    fleet_id,
                    device_id
                )
                VALUES ($1, $2, $3, $4, $5, $6)
                ON CONFLICT (uid) DO UPDATE SET
                    role = EXCLUDED.role,
                    email = EXCLUDED.email,
                    display_name = EXCLUDED.display_name,
                    fleet_id = EXCLUDED.fleet_id,
                    device_id = EXCLUDED.device_id,
                    updated_at = NOW()
                """,
                user.uid,
                role,
                email,
                display_name,
                fleet_id,
                device_id,
            )

        row = await _profile_row(user.uid)
        if row is None:
            raise HTTPException(status_code=500, detail="User profile was not saved")
        return _profile_response(row)

    @app.get("/users/{uid}")
    async def get_user(
        uid: str,
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        user = _auth_user(authorization)
        row = await _profile_row(uid)

        if row is None:
            raise HTTPException(status_code=404, detail="User not found")

        if uid != user.uid:
            requester = await _require_operator_profile(user)
            if row["role"] != "driver" or row["fleet_id"] != requester["fleet_id"]:
                raise HTTPException(status_code=403, detail="Not allowed to view this profile")

        return _profile_response(row)

    @app.get("/me")
    async def me(authorization: str | None = Header(None)) -> dict[str, Any]:
        user = _auth_user(authorization)
        row = await _require_current_profile(user)
        return _profile_response(row)

    @app.get("/fleet")
    async def get_fleet(authorization: str | None = Header(None)) -> dict[str, Any]:
        user = _auth_user(authorization)
        row = await _require_operator_profile(user)
        return {
            "id": row["fleet_id"],
            "name": row["fleet_name"],
            "invite_code": row["fleet_invite_code"],
        }

    @app.post("/fleet/join")
    async def join_fleet(
        data: dict,
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        user = _auth_user(authorization)
        invite_code = _normalize_invite_code(data.get("fleet_invite_code"))
        if not invite_code:
            raise HTTPException(status_code=400, detail="Missing fleet invite code")

        async with db.pool.acquire() as conn:
            fleet = await conn.fetchrow(
                "SELECT id FROM fleets WHERE invite_code = $1",
                invite_code,
            )
            if fleet is None:
                raise HTTPException(status_code=404, detail="Fleet invite code not found")

            device_id = _clean_optional_text(data.get("device_id"), 256) or user.uid
            await conn.execute(
                """
                INSERT INTO users (uid, role, email, display_name, fleet_id, device_id)
                VALUES ($1, 'driver', $2, $3, $4, $5)
                ON CONFLICT (uid) DO UPDATE SET
                    role = 'driver',
                    email = COALESCE(users.email, EXCLUDED.email),
                    display_name = COALESCE(users.display_name, EXCLUDED.display_name),
                    fleet_id = EXCLUDED.fleet_id,
                    device_id = EXCLUDED.device_id,
                    updated_at = NOW()
                """,
                user.uid,
                user.email,
                user.name or user.email,
                fleet["id"],
                device_id,
            )

        row = await _profile_row(user.uid)
        if row is None:
            raise HTTPException(status_code=500, detail="User profile was not saved")
        return _profile_response(row)

    @app.get("/fleet/drivers")
    async def fleet_drivers(authorization: str | None = Header(None)) -> dict[str, Any]:
        user = _auth_user(authorization)
        operator = await _require_operator_profile(user)

        async with db.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT
                    u.uid,
                    u.email,
                    u.display_name,
                    u.device_id,
                    (
                        ds.online IS TRUE
                        AND ds.last_seen >= NOW() - INTERVAL '45 seconds'
                    ) AS online,
                    ds.last_seen,
                    ds.metadata AS status_metadata,
                    ae.id AS alert_id,
                    ae.level AS alert_level,
                    ae.message AS alert_message,
                    ae.event_ts AS alert_event_ts,
                    ae.received_ts AS alert_received_ts,
                    ae.metadata AS alert_metadata,
                    ac.alert_count
                FROM users u
                LEFT JOIN device_status ds ON ds.device_id = u.device_id
                LEFT JOIN LATERAL (
                    SELECT id, level, message, event_ts, received_ts, metadata
                    FROM alert_events
                    WHERE (
                            device_id = u.device_id
                            AND received_ts >= NOW() - INTERVAL '5 minutes'
                        )
                    ORDER BY received_ts DESC
                    LIMIT 1
                ) ae ON TRUE
                LEFT JOIN LATERAL (
                    SELECT COUNT(*)::int AS alert_count
                    FROM alert_events
                    WHERE (
                            device_id = u.device_id
                            AND received_ts >= NOW() - INTERVAL '5 minutes'
                        )
                ) ac ON TRUE
                WHERE u.role = 'driver' AND u.fleet_id = $1
                ORDER BY
                    COALESCE(ae.received_ts, ds.last_seen, u.updated_at) DESC,
                    u.display_name ASC NULLS LAST,
                    u.email ASC NULLS LAST
                """,
                operator["fleet_id"],
            )

        drivers: list[dict[str, Any]] = []
        for row in rows:
            status_metadata = row["status_metadata"] if isinstance(row["status_metadata"], dict) else {}
            alert_metadata = row["alert_metadata"] if isinstance(row["alert_metadata"], dict) else {}
            fatigue_risk_percent = _metadata_percent(alert_metadata)
            if fatigue_risk_percent is None and row["online"]:
                fatigue_risk_percent = _metadata_percent(status_metadata)
            if fatigue_risk_percent is None:
                fatigue_risk_percent = _risk_from_alert_level(row["alert_level"])
            is_online = bool(row["online"]) if row["online"] is not None else False
            if row["alert_id"] is not None:
                is_online = True

            latest_alert = None
            if row["alert_id"] is not None:
                latest_alert = {
                    "id": row["alert_id"],
                    "level": row["alert_level"],
                    "message": row["alert_message"],
                    "event_ts": _iso(row["alert_event_ts"]),
                    "received_ts": _iso(row["alert_received_ts"]),
                    "metadata": alert_metadata,
                    "fatigue_risk_percent": fatigue_risk_percent,
                }

            drivers.append(
                {
                    "uid": row["uid"],
                    "email": row["email"],
                    "display_name": row["display_name"],
                    "device_id": row["device_id"],
                    "online": is_online,
                    "last_seen": _iso(row["last_seen"]),
                    "status_metadata": status_metadata,
                    "alert_count": row["alert_count"] or 0,
                    "fatigue_risk_percent": fatigue_risk_percent,
                    "fatigue_status": _fatigue_status(fatigue_risk_percent),
                    "latest_alert": latest_alert,
                    "metrics": {
                        "online": is_online,
                        "last_seen": _iso(row["last_seen"]),
                        "alert_count": row["alert_count"] or 0,
                        "fatigue_risk_percent": fatigue_risk_percent,
                        "fatigue_status": _fatigue_status(fatigue_risk_percent),
                        "latest_alert_level": row["alert_level"],
                        "latest_alert_at": _iso(row["alert_event_ts"] or row["alert_received_ts"]),
                    },
                },
            )

        return {
            "fleet": {
                "id": operator["fleet_id"],
                "name": operator["fleet_name"],
                "invite_code": operator["fleet_invite_code"],
            },
            "drivers": drivers,
        }

    def _alert_history_response(rows) -> list[dict[str, Any]]:
        return [
            {
                "id": row["id"],
                "device_id": row["device_id"],
                "level": row["level"],
                "message": row["message"],
                "event_ts": _iso(row["event_ts"]),
                "received_ts": _iso(row["received_ts"]),
                "metadata": row["metadata"] if isinstance(row["metadata"], dict) else {},
            }
            for row in rows
        ]

    @app.get("/me/alerts")
    async def my_alerts(
        limit: int = Query(default=50, ge=1, le=500),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        user = _auth_user(authorization)
        profile = await _require_current_profile(user)
        if profile["role"] != "driver":
            raise HTTPException(status_code=403, detail="Driver role required")
        if not profile["device_id"]:
            return {"items": []}

        async with db.pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT id, device_id, level, message, event_ts, received_ts, metadata
                FROM alert_events
                WHERE device_id = $1
                ORDER BY received_ts DESC
                LIMIT $2
                """,
                profile["device_id"],
                limit,
            )
        return {"items": _alert_history_response(rows)}

    @app.get("/fleet/drivers/{driver_uid}/alerts")
    async def fleet_driver_alerts(
        driver_uid: str,
        limit: int = Query(default=50, ge=1, le=500),
        authorization: str | None = Header(None),
    ) -> dict[str, Any]:
        user = _auth_user(authorization)
        operator = await _require_operator_profile(user)

        async with db.pool.acquire() as conn:
            driver = await conn.fetchrow(
                """
                SELECT uid, device_id
                FROM users
                WHERE uid = $1 AND role = 'driver' AND fleet_id = $2
                """,
                driver_uid,
                operator["fleet_id"],
            )
            if driver is None:
                raise HTTPException(status_code=404, detail="Fleet driver not found")
            if not driver["device_id"]:
                return {"items": []}

            rows = await conn.fetch(
                """
                SELECT id, device_id, level, message, event_ts, received_ts, metadata
                FROM alert_events
                WHERE device_id = $1
                ORDER BY received_ts DESC
                LIMIT $2
                """,
                driver["device_id"],
                limit,
            )

        return {"items": _alert_history_response(rows)}

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
