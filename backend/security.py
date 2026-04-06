from __future__ import annotations

import hashlib
import hmac

from starlette.datastructures import MutableHeaders


def gateway_key_matches(provided: str | None, expected: str) -> bool:
    """Constant-time comparison of API keys (length-independent). Call only when `expected` is set."""

    p = (provided or "").encode("utf-8")
    e = expected.encode("utf-8")
    return hmac.compare_digest(
        hashlib.sha256(p).digest(),
        hashlib.sha256(e).digest(),
    )


class SecurityHeadersMiddleware:
    """Baseline HTTP hardening (TLS is terminated upstream on Render). Pure ASGI so WebSockets work."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)  # mutates message["headers"] in place
                headers.setdefault("X-Content-Type-Options", "nosniff")
                headers.setdefault("X-Frame-Options", "DENY")
                headers.setdefault("Referrer-Policy", "no-referrer")
                headers.setdefault(
                    "Permissions-Policy",
                    "geolocation=(), microphone=(), camera=(), payment=()",
                )
            await send(message)

        await self.app(scope, receive, send_with_headers)
