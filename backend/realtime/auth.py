from __future__ import annotations

from dataclasses import dataclass

import jwt
from fastapi import HTTPException


@dataclass(frozen=True)
class AuthUser:
    uid: str
    email: str | None = None
    name: str | None = None


def require_jwt_user(
    *,
    authorization: str | None,
    secret: str,
) -> AuthUser:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing token")

    token = authorization[7:].strip()
    if not token:
        raise HTTPException(status_code=401, detail="Missing token")

    try:
        payload = jwt.decode(token, secret, algorithms=["HS256"])
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Invalid token") from exc

    uid = payload.get("sub")
    if not isinstance(uid, str) or not uid:
        raise HTTPException(status_code=401, detail="Invalid token")

    email = payload.get("email")
    return AuthUser(
        uid=uid,
        email=email if isinstance(email, str) else None,
    )
