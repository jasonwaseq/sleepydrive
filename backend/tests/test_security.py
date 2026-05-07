from __future__ import annotations

import pytest

from security import SecurityHeadersMiddleware, gateway_key_matches


# ---------------------------------------------------------------------------
# gateway_key_matches
# ---------------------------------------------------------------------------

def test_gateway_key_matches_same_key():
    assert gateway_key_matches("secret-key", "secret-key") is True


def test_gateway_key_matches_different_key():
    assert gateway_key_matches("wrong-key", "secret-key") is False


def test_gateway_key_matches_none_provided():
    assert gateway_key_matches(None, "secret-key") is False


def test_gateway_key_matches_empty_provided():
    assert gateway_key_matches("", "secret-key") is False


# ---------------------------------------------------------------------------
# SecurityHeadersMiddleware
# ---------------------------------------------------------------------------

async def test_security_headers_http_scope():
    captured = []

    async def inner_app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})

    async def outer_send(message):
        captured.append(message)

    mw = SecurityHeadersMiddleware(inner_app)
    await mw({"type": "http"}, None, outer_send)

    assert len(captured) == 1
    hdrs = dict(captured[0]["headers"])
    assert hdrs[b"x-content-type-options"] == b"nosniff"
    assert hdrs[b"x-frame-options"] == b"DENY"
    assert hdrs[b"referrer-policy"] == b"no-referrer"
    assert b"permissions-policy" in hdrs


async def test_security_headers_does_not_overwrite_existing():
    captured = []

    async def inner_app(scope, receive, send):
        await send({
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"x-content-type-options", b"existing-value")],
        })

    async def outer_send(message):
        captured.append(message)

    mw = SecurityHeadersMiddleware(inner_app)
    await mw({"type": "http"}, None, outer_send)

    hdrs = dict(captured[0]["headers"])
    assert hdrs[b"x-content-type-options"] == b"existing-value"


async def test_security_headers_websocket_passthrough():
    inner_received_send = []

    async def inner_app(scope, receive, send):
        inner_received_send.append(send)

    async def outer_send(message):
        pass

    mw = SecurityHeadersMiddleware(inner_app)
    scope = {"type": "websocket"}
    await mw(scope, None, outer_send)

    assert len(inner_received_send) == 1
    assert inner_received_send[0] is outer_send
