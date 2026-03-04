from __future__ import annotations

import asyncio
import logging
import ssl
from collections.abc import Awaitable, Callable

from aiomqtt import Client, MqttError

from repository import AlertRepository
from schemas import AlertEvent, parse_mqtt_payload
from settings import Settings

log = logging.getLogger("realtime.mqtt")


class MQTTConsumer:
    def __init__(
        self,
        settings: Settings,
        repository: AlertRepository,
        on_event: Callable[[AlertEvent], Awaitable[None]],
    ):
        self._settings = settings
        self._repository = repository
        self._on_event = on_event

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
                log.info("Subscribed to MQTT topic: %s", topic)

            async for message in messages:
                if stop_event.is_set():
                    break
                topic = str(message.topic)
                payload = bytes(message.payload)
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
        event = parse_mqtt_payload(topic=topic, payload=payload)
        saved = await self._repository.insert(event)
        await self._on_event(saved)
        log.info("Event persisted and broadcast: device=%s level=%s", saved.device_id, saved.level)
