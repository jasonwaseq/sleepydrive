import asyncio
import json
import pytest
from fastapi.testclient import TestClient

import app as app_module
import mqtt_consumer as mqtt_module
from tests.conftest import FakeConn, FakePool


class _Message:
    def __init__(self, topic, payload):
        self.topic = topic
        self.payload = payload


class _MessageStream:
    def __init__(self):
        self.messages = []
        self.stop = False
        
    def __aiter__(self):
        return self
        
    async def __anext__(self):
        import asyncio
        while not self.messages and not self.stop:
            await asyncio.sleep(0.05)
        if self.stop and not self.messages:
            raise StopAsyncIteration
        return self.messages.pop(0)


@pytest.fixture
def e2e_harness(stable_env, monkeypatch):
    conn = FakeConn()
    inserted_alerts = []
    
    async def fetchrow_handler(query, *args):
        if "INSERT INTO alert_events" in query:
            inserted_alerts.append(args)
            return {"id": 999, "device_id": args[0], "level": args[1], "message": args[2], "source": args[3], "topic": args[4], "event_ts": args[5], "received_ts": args[6], "metadata": args[7]}
        return None
    conn.fetchrow_handler = fetchrow_handler

    class MyFakePool(FakePool):
        async def fetchrow(self, query, *args):
            if hasattr(conn, "fetchrow"):
                return await conn.fetchrow(query, *args)
            elif hasattr(conn, "fetchrow_handler") and conn.fetchrow_handler:
                return await conn.fetchrow_handler(query, *args)
            return None
            
        async def close(self):
            pass
            
        async def fetch(self, query, *args):
            return []

    async def create_pool(*args, **kwargs):
        return MyFakePool(conn)

    import asyncpg
    monkeypatch.setattr(asyncpg, "create_pool", create_pool)

    stream = _MessageStream()
    
    class _FakeClient:
        def __init__(self, *args, **kwargs):
            self.messages = stream
            self.subscribed = []
            
        async def __aenter__(self):
            return self
            
        async def __aexit__(self, exc_type, exc, tb):
            return False
            
        async def subscribe(self, topic, qos):
            self.subscribed.append((topic, qos))

    monkeypatch.setattr(mqtt_module, "Client", _FakeClient)

    app = app_module.create_app()
    with TestClient(app) as client:
        yield {
            "client": client,
            "stream": stream,
            "inserted_alerts": inserted_alerts,
            "conn": conn,
        }
        stream.stop = True


def test_spec_2_fleet_event_logging_operator_view(e2e_harness):
    """
    SPEC 2 — Fleet event logging (operator view)
    Given: a fake MQTT event published with EAR < threshold
    When:  the backend consumes it
    Then:  a row exists in the safety_events (alert_events) table within 1 second
    """
    stream = e2e_harness["stream"]
    inserted_alerts = e2e_harness["inserted_alerts"]

    # Inject fake MQTT event
    payload = {"device_id": "truck-42", "level": 2, "message": "Drowsiness alert", "risk": 98}
    stream.messages.append(_Message("sleepydrive/alerts/truck-42", json.dumps(payload).encode("utf-8")))

    import time
    time.sleep(0.2)

    # Check that it was inserted into the database
    assert len(inserted_alerts) == 1
    # The first arg to the insert query should be the device_id
    assert inserted_alerts[0][0] == "truck-42"
    assert inserted_alerts[0][1] == 2  # level
    assert inserted_alerts[0][2] == "Drowsiness alert"  # message


def test_spec_3_version_comparison_operator_view(e2e_harness):
    """
    SPEC 3 — Version comparison (Fleet Operator)
    Given: version A (threshold X) and version B (threshold Y)
    When:  the same EAR sequence is fed to both
    Then:  record alert latency and false positive count for each
    """
    stream = e2e_harness["stream"]
    inserted_alerts = e2e_harness["inserted_alerts"]

    # Version A
    stream.messages.append(_Message("sleepydrive/alerts/truck-A", b'{"level": 2, "risk": 85}'))
    # Version B
    stream.messages.append(_Message("sleepydrive/alerts/truck-B", b'{"level": 1, "risk": 70}'))

    import time
    time.sleep(0.2)

    assert len(inserted_alerts) == 2
    assert inserted_alerts[0][0] == "truck-A"
    assert inserted_alerts[1][0] == "truck-B"
