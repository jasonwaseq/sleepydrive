from __future__ import annotations

import pytest

from settings import (
    Settings,
    _derive_status_topic,
    _env_bool_names,
    _env_int_names,
    _trusted_hosts_from_env,
)


# ---------------------------------------------------------------------------
# _derive_status_topic
# ---------------------------------------------------------------------------

def test_derive_status_topic_alerts_in_path():
    assert _derive_status_topic("sleepydrive/alerts/jetson") == "sleepydrive/status/jetson"


def test_derive_status_topic_ends_with_alerts_plus():
    assert _derive_status_topic("sleepydrive/alerts/+") == "sleepydrive/status/+"


def test_derive_status_topic_ends_with_alerts_hash():
    assert _derive_status_topic("sleepydrive/alerts/#") == "sleepydrive/status/#"


def test_derive_status_topic_no_match():
    assert _derive_status_topic("some/other/topic") == "sleepydrive/status/+"


def test_derive_status_topic_empty():
    assert _derive_status_topic("") == "sleepydrive/status/+"


# ---------------------------------------------------------------------------
# _env_bool_names
# ---------------------------------------------------------------------------

def test_env_bool_names_truthy(monkeypatch):
    for val in ("1", "true", "yes", "on"):
        monkeypatch.setenv("TEST_BOOL", val)
        assert _env_bool_names(("TEST_BOOL",), False) is True, f"expected True for {val!r}"


def test_env_bool_names_falsy(monkeypatch):
    for val in ("0", "false", "no", "off"):
        monkeypatch.setenv("TEST_BOOL", val)
        assert _env_bool_names(("TEST_BOOL",), True) is False, f"expected False for {val!r}"


def test_env_bool_names_absent_uses_default(monkeypatch):
    monkeypatch.delenv("TEST_BOOL", raising=False)
    assert _env_bool_names(("TEST_BOOL",), True) is True
    assert _env_bool_names(("TEST_BOOL",), False) is False


# ---------------------------------------------------------------------------
# _env_int_names
# ---------------------------------------------------------------------------

def test_env_int_names_valid(monkeypatch):
    monkeypatch.setenv("TEST_INT", "42")
    assert _env_int_names(("TEST_INT",), 0) == 42


def test_env_int_names_invalid_string(monkeypatch):
    monkeypatch.setenv("TEST_INT", "notanint")
    assert _env_int_names(("TEST_INT",), 99) == 99


def test_env_int_names_absent(monkeypatch):
    monkeypatch.delenv("TEST_INT", raising=False)
    assert _env_int_names(("TEST_INT",), 7) == 7


# ---------------------------------------------------------------------------
# _trusted_hosts_from_env
# ---------------------------------------------------------------------------

def test_trusted_hosts_from_env_comma_list(monkeypatch):
    monkeypatch.setenv("TRUSTED_HOSTS", "a.com, b.com, c.com")
    result = _trusted_hosts_from_env()
    assert result == ("a.com", "b.com", "c.com")


def test_trusted_hosts_from_env_absent(monkeypatch):
    monkeypatch.delenv("TRUSTED_HOSTS", raising=False)
    assert _trusted_hosts_from_env() == ("*",)


def test_trusted_hosts_from_env_whitespace_only(monkeypatch):
    monkeypatch.setenv("TRUSTED_HOSTS", "   ")
    assert _trusted_hosts_from_env() == ("*",)


# ---------------------------------------------------------------------------
# Settings.from_env
# ---------------------------------------------------------------------------

_ALL_VARS = [
    "APP_HOST", "APP_PORT", "DATABASE_URL",
    "MQTT_HOST", "MP_QTT_HOST", "MQTT_PORT", "MP_QTT_PORT",
    "MQTT_USERNAME", "MP_QTT_USERNAME", "MQTT_PASSWORD", "MP_QTT_PASSWORD",
    "MQTT_CLIENT_ID", "MP_QTT_CLIENT_ID", "MQTT_QOS", "MP_QTT_QOS",
    "MQTT_RECONNECT_SECONDS", "MP_QTT_RECONNECT_SECONDS",
    "MQTT_TOPICS", "MP_QTT_TOPIC", "MQTT_STATUS_TOPICS", "MP_QTT_STATUS_TOPIC",
    "MQTT_TLS", "MP_QTT_TLS", "MQTT_TLS_INSECURE", "MP_QTT_TLS_INSECURE",
    "MQTT_CA_CERT", "MP_QTT_CA_CERT", "MQTT_CLIENT_CERT", "MP_QTT_CLIENT_CERT",
    "MQTT_CLIENT_KEY", "MP_QTT_CLIENT_KEY",
    "WS_DEFAULT_REPLAY", "WS_IDLE_PING_SECONDS", "WS_MAX_INCOMING_BYTES",
    "GATEWAY_API_KEY", "API_KEY", "TRUSTED_HOSTS",
    "MAX_MQTT_PAYLOAD_BYTES", "DB_COMMAND_TIMEOUT_SECONDS",
    "CORS_ALLOW_ORIGINS", "JWT_SECRET", "JWT_EXPIRY_HOURS",
]


@pytest.fixture()
def clean_env(monkeypatch):
    for var in _ALL_VARS:
        monkeypatch.delenv(var, raising=False)


def test_settings_from_env_defaults(clean_env):
    s = Settings.from_env()
    assert s.database_url == "postgresql://sleepydrive:sleepydrive@localhost:5432/sleepydrive"
    assert s.mqtt_host == "localhost"
    assert s.app_port == 8080
    assert s.jwt_expiry_hours == 168
    assert s.gateway_api_key is None
    assert s.mqtt_tls_enabled is False
    assert s.mqtt_username is None
    assert s.mqtt_password is None


def test_settings_mqtt_topics_comma_separated(clean_env, monkeypatch):
    monkeypatch.setenv("MQTT_TOPICS", "a/alerts/+, b/alerts/+")
    s = Settings.from_env()
    assert "a/alerts/+" in s.mqtt_topics
    assert "b/alerts/+" in s.mqtt_topics
    assert "a/status/+" in s.mqtt_topics
    assert "b/status/+" in s.mqtt_topics


def test_settings_status_topics_override(clean_env, monkeypatch):
    monkeypatch.setenv("MQTT_TOPICS", "sleepydrive/alerts/+")
    monkeypatch.setenv("MQTT_STATUS_TOPICS", "custom/status/+")
    s = Settings.from_env()
    assert "custom/status/+" in s.mqtt_topics
    assert "sleepydrive/status/+" not in s.mqtt_topics


def test_settings_tls_fields(clean_env, monkeypatch):
    monkeypatch.setenv("MQTT_TLS", "true")
    monkeypatch.setenv("MQTT_CA_CERT", "/path/to/ca.pem")
    monkeypatch.setenv("MQTT_CLIENT_CERT", "/path/to/client.pem")
    monkeypatch.setenv("MQTT_CLIENT_KEY", "/path/to/client.key")
    s = Settings.from_env()
    assert s.mqtt_tls_enabled is True
    assert s.mqtt_ca_cert == "/path/to/ca.pem"
    assert s.mqtt_client_cert == "/path/to/client.pem"
    assert s.mqtt_client_key == "/path/to/client.key"


def test_settings_gateway_api_key_set(clean_env, monkeypatch):
    monkeypatch.setenv("GATEWAY_API_KEY", "my-api-key")
    s = Settings.from_env()
    assert s.gateway_api_key == "my-api-key"


def test_settings_gateway_api_key_absent(clean_env):
    s = Settings.from_env()
    assert s.gateway_api_key is None


def test_settings_jwt_secret_from_env(clean_env, monkeypatch):
    monkeypatch.setenv("JWT_SECRET", "my-secret")
    s = Settings.from_env()
    assert s.jwt_secret == "my-secret"


def test_settings_jwt_secret_random_when_absent(clean_env):
    s1 = Settings.from_env()
    s2 = Settings.from_env()
    assert len(s1.jwt_secret) == 64
    assert s1.jwt_secret != s2.jwt_secret


def test_settings_topic_deduplication(clean_env, monkeypatch):
    monkeypatch.setenv("MQTT_TOPICS", "x/+")
    monkeypatch.setenv("MQTT_STATUS_TOPICS", "x/+, y/+")
    s = Settings.from_env()
    assert s.mqtt_topics.count("x/+") == 1
    assert "y/+" in s.mqtt_topics


def test_settings_max_mqtt_payload_floor(clean_env, monkeypatch):
    monkeypatch.setenv("MAX_MQTT_PAYLOAD_BYTES", "100")
    s = Settings.from_env()
    assert s.max_mqtt_payload_bytes == 4096


def test_settings_qos_clamped(clean_env, monkeypatch):
    monkeypatch.setenv("MQTT_QOS", "5")
    s = Settings.from_env()
    assert s.mqtt_qos == 2
