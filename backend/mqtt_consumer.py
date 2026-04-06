from __future__ import annotations

import asyncio
import logging
import ssl
from collections.abc import Awaitable, Callable

from aiomqtt import Client, MqttError

from repository import AlertRepository
from schemas import AlertEvent, JetsonPresence, parse_mqtt_payload, parse_presence_payload
from settings import Settings

log = logging.getLogger("realtime.mqtt")


class MQTTConsumer:
    def __init__(
        self,
        settings: Settings,
        repository: AlertRepository,
        on_event: Callable[[AlertEvent], Awaitable[None]],
        on_presence: Callable[[JetsonPresence], Awaitable[None]] | None = None,
    ):
        self._settings = settings
        self._repository = repository
        self._on_event = on_event
        self._on_presence = on_presence

    async def run(self, stop_event: asyncio.Event) -> None:
        while not stop_event.is_set():
            try:
                await self._consume_until_error(stop_event)
            except asyncio.CancelledError:
                raise
            except MqttError as exc:
                log.warning("MQTT connection error: %s", exc)
            except Exception:
                log.exception("Unexpected error in MQTT loop")

            if stop_event.is_set():
                break

            try:
                await asyncio.wait_for(
                    stop_event.wait(),
                    timeout=self._settings.mqtt_reconnect_seconds,
                )
            except asyncio.TimeoutError:
                pass

    async def _consume_until_error(self, stop_event: asyncio.Event) -> None:
        kwargs = {}
        if self._settings.mqtt_username:
            kwargs["username"] = self._settings.mqtt_username
        if self._settings.mqtt_password:
            kwargs["password"] = self._settings.mqtt_password
        tls_context = self._build_tls_context()
        if tls_context is not None:
            kwargs["tls_context"] = tls_context

        async with Client(
            hostname=self._settings.mqtt_host,
            port=self._settings.mqtt_port,
            identifier=self._settings.mqtt_client_id,
            **kwargs,
        ) as client:
            messages = client.messages
            for topic in self._settings.mqtt_topics:
                await client.subscribe(topic, qos=self._settings.mqtt_qos)
                log.info("Subscribed to MQTT topic: %s (qos=%s)", topic, self._settings.mqtt_qos)

            async for message in messages:
                if stop_event.is_set():
                    break
                topic = str(message.topic)
                payload = bytes(message.payload)
                max_b = self._settings.max_mqtt_payload_bytes
                if len(payload) > max_b:
                    log.warning(
                        "MQTT payload %d bytes exceeds max %d; truncating",
                        len(payload),
                        max_b,
                    )
                    payload = payload[:max_b]
                await self._handle_message(topic=topic, payload=payload)

    def _build_tls_context(self) -> ssl.SSLContext | None:
        if not self._settings.mqtt_tls_enabled:
            return None

        context = ssl.create_default_context()
        if self._settings.mqtt_ca_cert:
            context.load_verify_locations(cafile=self._settings.mqtt_ca_cert)
        if self._settings.mqtt_client_cert:
            context.load_cert_chain(
                certfile=self._settings.mqtt_client_cert,
                keyfile=self._settings.mqtt_client_key,
            )
        if self._settings.mqtt_tls_insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        return context

    async def _handle_message(self, topic: str, payload: bytes) -> None:
        presence = parse_presence_payload(topic=topic, payload=payload)
        if presence is not None:
            await self._notify_presence(presence)
            log.info("Presence update: source=%s online=%s", presence.source_id, presence.online)
            return

        event = parse_mqtt_payload(topic=topic, payload=payload)
        saved = await self._repository.insert(event)
        await self._notify_event(saved)
        log.info("Event persisted and broadcast: device=%s level=%s", saved.device_id, saved.level)

    async def _notify_event(self, saved: AlertEvent) -> None:
        try:
            await self._on_event(saved)
        except Exception:
            log.exception(
                "WebSocket broadcast failed after DB persist (device=%s id=%s); "
                "MQTT message will still be acked to avoid duplicate rows",
                saved.device_id,
                saved.id,
            )

    async def _notify_presence(self, presence: JetsonPresence) -> None:
        if self._on_presence is None:
            return
        try:
            await self._on_presence(presence)
        except Exception:
            log.exception(
                "Presence broadcast failed (source=%s); MQTT message still acked",
                presence.source_id,
            )
