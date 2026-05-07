from __future__ import annotations

from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi import HTTPException

from auth import AuthUser, issue_token, require_jwt_user

SECRET = "test-secret-key"


def _make_token(uid="user-1", email="a@b.com", secret=SECRET, expiry_hours=1):
    return issue_token(uid, email, secret, expiry_hours)


def _expired_token(uid="user-1", secret=SECRET):
    now = datetime.now(timezone.utc)
    payload = {
        "sub": uid,
        "iat": now - timedelta(hours=2),
        "exp": now - timedelta(hours=1),
    }
    return jwt.encode(payload, secret, algorithm="HS256")


# ---------------------------------------------------------------------------
# issue_token
# ---------------------------------------------------------------------------

def test_issue_token_is_decodable():
    token = _make_token()
    payload = jwt.decode(token, SECRET, algorithms=["HS256"])
    assert isinstance(payload, dict)


def test_issue_token_sub_field():
    token = _make_token(uid="uid-abc")
    payload = jwt.decode(token, SECRET, algorithms=["HS256"])
    assert payload["sub"] == "uid-abc"


def test_issue_token_email_field():
    token = _make_token(email="test@example.com")
    payload = jwt.decode(token, SECRET, algorithms=["HS256"])
    assert payload["email"] == "test@example.com"


def test_issue_token_expiry():
    token = _make_token(expiry_hours=24)
    payload = jwt.decode(token, SECRET, algorithms=["HS256"])
    exp = datetime.fromtimestamp(payload["exp"], tz=timezone.utc)
    now = datetime.now(timezone.utc)
    assert timedelta(hours=23, minutes=55) < (exp - now) < timedelta(hours=24, minutes=5)


# ---------------------------------------------------------------------------
# require_jwt_user
# ---------------------------------------------------------------------------

def test_require_jwt_user_valid():
    token = _make_token(uid="user-42", email="hi@example.com")
    user = require_jwt_user(authorization=f"Bearer {token}", secret=SECRET)
    assert isinstance(user, AuthUser)
    assert user.uid == "user-42"
    assert user.email == "hi@example.com"


def test_require_jwt_user_missing_header():
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization=None, secret=SECRET)
    assert exc.value.status_code == 401


def test_require_jwt_user_no_bearer_prefix():
    token = _make_token()
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization=token, secret=SECRET)
    assert exc.value.status_code == 401


def test_require_jwt_user_empty_token():
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization="Bearer   ", secret=SECRET)
    assert exc.value.status_code == 401


def test_require_jwt_user_expired_token():
    token = _expired_token()
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization=f"Bearer {token}", secret=SECRET)
    assert exc.value.status_code == 401


def test_require_jwt_user_wrong_secret():
    token = _make_token(secret="other-secret")
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization=f"Bearer {token}", secret=SECRET)
    assert exc.value.status_code == 401


def test_require_jwt_user_missing_sub():
    payload = {"email": "a@b.com", "exp": datetime.now(timezone.utc) + timedelta(hours=1)}
    token = jwt.encode(payload, SECRET, algorithm="HS256")
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization=f"Bearer {token}", secret=SECRET)
    assert exc.value.status_code == 401


def test_require_jwt_user_non_string_sub():
    payload = {"sub": 12345, "exp": datetime.now(timezone.utc) + timedelta(hours=1)}
    token = jwt.encode(payload, SECRET, algorithm="HS256")
    with pytest.raises(HTTPException) as exc:
        require_jwt_user(authorization=f"Bearer {token}", secret=SECRET)
    assert exc.value.status_code == 401
