import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from can_monitor.api.app import create_app
from can_monitor.config import Settings
from can_monitor.domain.models import CanFrame, CanInterfaceInfo, Direction
from tests.fakes import FakeAdapter, FakeDiscoverer


def _settings(**overrides) -> Settings:
    values = {
        "trace_buffer_size": 4,
        "client_queue_size": 4,
        "websocket_batch_size": 10,
        "websocket_batch_interval_ms": 1,
        "cors_origins": (),
    }
    values.update(overrides)
    return Settings(**values)


def _make_app(interface: CanInterfaceInfo, **settings_overrides):
    adapters: list[FakeAdapter] = []

    def factory() -> FakeAdapter:
        adapter = FakeAdapter()
        adapters.append(adapter)
        return adapter

    app = create_app(
        _settings(**settings_overrides),
        adapter_factory=factory,
        discoverer=FakeDiscoverer([interface]),
    )
    return app, adapters


def _create(client: TestClient, interface: str = "vcan0", **extra):
    payload = {"interface": interface, "filter": {"mode": "all", "ids": []}}
    payload.update(extra)
    response = client.post("/api/v1/can/sessions", json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def test_interfaces_session_filters_timing_and_disconnect() -> None:
    interface = CanInterfaceInfo("vcan0", "vcan", True, "unknown", fd_enabled=True)
    app, adapters = _make_app(interface)
    with TestClient(app) as client:
        assert client.get("/api/v1/health").json() == {"status": "ok"}
        listed = client.get("/api/v1/can/interfaces").json()["interfaces"]
        assert listed[0]["name"] == "vcan0"
        session = _create(client)
        session_id = session["id"]
        assert session["state"] == "connected"
        assert adapters[0].opened is not None

        updated = client.put(
            f"/api/v1/can/sessions/{session_id}/filters",
            json={
                "mode": "filtered",
                "ids": [
                    {"can_id": 0x123, "is_extended_id": False},
                    {"can_id": 0x123, "is_extended_id": True},
                ],
            },
        )
        assert updated.status_code == 200
        assert updated.json()["filter_revision"] == 2
        assert len(adapters[0].filters) == 1
        assert client.get(f"/api/v1/can/sessions/{session_id}/timing").json() == {
            "statistics": []
        }

        deleted = client.delete(f"/api/v1/can/sessions/{session_id}")
        assert deleted.status_code == 200
        assert deleted.json()["state"] == "disconnected"
        assert adapters[0].closed


def test_validation_conflict_not_found_and_problem_json() -> None:
    app, _ = _make_app(CanInterfaceInfo("vcan0", "vcan"))
    with TestClient(app) as client:
        missing = client.post(
            "/api/v1/can/sessions",
            json={"interface": "can9", "filter": {"mode": "all", "ids": []}},
        )
        assert missing.status_code == 404
        assert missing.headers["content-type"].startswith("application/problem+json")
        assert missing.json()["code"] == "not_found"

        _create(client)
        conflict = client.post(
            "/api/v1/can/sessions",
            json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
        )
        assert conflict.status_code == 409
        invalid = client.put(
            "/api/v1/can/sessions/not-a-session/filters",
            json={"mode": "filtered", "ids": []},
        )
        assert invalid.status_code == 422
        assert invalid.json()["code"] == "validation_error"
        leaked = client.post(
            "/api/v1/can/sessions",
            json={
                "interface": "vcan0",
                "filter": {"mode": "all", "ids": []},
                "unexpected": "do-not-reflect-this-value",
            },
        )
        assert leaked.status_code == 422
        assert "do-not-reflect-this-value" not in leaked.json()["detail"]


def test_physical_tx_disabled_but_vcan_tx_enabled_by_default() -> None:
    physical_app, _ = _make_app(CanInterfaceInfo("can0", "can"))
    with TestClient(physical_app) as client:
        assert client.get("/api/v1/can/tx-enabled").json() == {"enabled": False}
        session = _create(client, "can0")
        response = client.post(
            f"/api/v1/can/sessions/{session['id']}/frames",
            json={"can_id": 0x123, "data_hex": "01 0A FF"},
        )
        assert response.status_code == 403
        assert response.json()["code"] == "transmission_disabled"

    virtual_app, adapters = _make_app(CanInterfaceInfo("vcan0", "vcan"))
    with TestClient(virtual_app) as client:
        session = _create(client)
        response = client.post(
            f"/api/v1/can/sessions/{session['id']}/frames",
            json={"can_id": 0x123, "data_hex": "01 0A FF"},
        )
        assert response.status_code == 202
        assert adapters[0].sent[0].data == b"\x01\x0a\xff"


def test_physical_tx_can_be_enabled_and_disabled_at_runtime() -> None:
    app, adapters = _make_app(
        CanInterfaceInfo("can0", "can"),
        tx_rate_limit_per_second=2,
    )
    with TestClient(app) as client:
        assert client.get("/api/v1/can/tx-enabled").json() == {"enabled": False}
        session = _create(client, "can0")
        path = f"/api/v1/can/sessions/{session['id']}/frames"
        body = {"can_id": 0x123, "data_hex": "01"}
        assert client.post(path, json=body).status_code == 403
        enabled = client.put("/api/v1/can/tx-enabled", json={"enabled": True})
        assert enabled.json() == {"enabled": True}
        assert client.get("/api/v1/can/tx-enabled").json() == {"enabled": True}
        assert client.post(path, json=body).status_code == 202
        assert client.post(path, json=body).status_code == 202
        limited = client.post(path, json=body)
        assert limited.status_code == 429
        assert limited.json()["code"] == "rate_limit_exceeded"
        assert len(adapters[0].sent) == 2
        disabled = client.put("/api/v1/can/tx-enabled", json={"enabled": False})
        assert disabled.json() == {"enabled": False}
        assert client.post(path, json=body).status_code == 403

    virtual_app, _ = _make_app(
        CanInterfaceInfo("vcan0", "vcan"), tx_rate_limit_per_second=1
    )
    with TestClient(virtual_app) as client:
        session = _create(client)
        path = f"/api/v1/can/sessions/{session['id']}/frames"
        assert client.post(path, json=body).status_code == 202
        assert client.post(path, json=body).status_code == 429


def test_websocket_hello_and_frame_batch_contract() -> None:
    app, adapters = _make_app(CanInterfaceInfo("vcan0", "vcan"))
    with TestClient(app) as client:
        session = _create(client)
        with client.websocket_connect(
            f"/api/v1/can/sessions/{session['id']}/stream"
        ) as websocket:
            hello = websocket.receive_json()
            assert hello["type"] == "hello"
            assert hello["version"] == 1
            adapters[0].emit(
                CanFrame(
                    capture_timestamp_ns=1_234_567_890,
                    ingress_monotonic_ns=99,
                    interface="vcan0",
                    can_id=0x123,
                    is_extended_id=False,
                    is_fd=False,
                    dlc=2,
                    data=b"\x01\xff",
                    direction=Direction.RX,
                )
            )
            event = websocket.receive_json()
            assert event["type"] == "frames"
            assert event["version"] == 1
            assert event["frames"][0]["timestamp_ns"] == "1234567890"
            assert event["frames"][0]["data_hex"] == "01FF"
            assert event["frames"][0]["direction"] == "rx"


def test_disabling_physical_tx_keeps_acquisition_and_websocket_active() -> None:
    app, adapters = _make_app(
        CanInterfaceInfo("can0", "can"),
        tx_enabled=True,
    )
    with TestClient(app) as client:
        assert client.get("/api/v1/can/tx-enabled").json() == {"enabled": True}
        session = _create(client, "can0")
        path = f"/api/v1/can/sessions/{session['id']}/stream"
        with client.websocket_connect(path) as websocket:
            assert websocket.receive_json()["type"] == "hello"
            assert client.put(
                "/api/v1/can/tx-enabled", json={"enabled": False}
            ).json() == {"enabled": False}
            adapters[0].emit(
                CanFrame(
                    capture_timestamp_ns=2_000_000_000,
                    ingress_monotonic_ns=200,
                    interface="can0",
                    can_id=0x321,
                    is_extended_id=False,
                    is_fd=False,
                    dlc=1,
                    data=b"\xaa",
                    direction=Direction.RX,
                )
            )
            event = websocket.receive_json()
            assert event["frames"][0]["data_hex"] == "AA"
            assert client.get(f"/api/v1/can/sessions/{session['id']}").json()[
                "state"
            ] == "connected"


def test_websocket_origin_must_match_cors_allowlist() -> None:
    origin = "https://allowed.example"
    app, _ = _make_app(
        CanInterfaceInfo("vcan0", "vcan"), cors_origins=(origin,)
    )
    with TestClient(app) as client:
        session = _create(client)
        path = f"/api/v1/can/sessions/{session['id']}/stream"
        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect(path):
                pass
        assert rejected.value.code == 4403

        with client.websocket_connect(path, headers={"origin": origin}) as websocket:
            assert websocket.receive_json()["type"] == "hello"


def test_cors_preflight_allows_json_runtime_tx_control() -> None:
    origin = "https://allowed.example"
    app, _ = _make_app(
        CanInterfaceInfo("can0", "can"), cors_origins=(origin,)
    )
    with TestClient(app) as client:
        response = client.options(
            "/api/v1/can/tx-enabled",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "PUT",
                "Access-Control-Request-Headers": "content-type",
            },
        )

    assert response.status_code == 200
    allowed = response.headers["access-control-allow-headers"].lower()
    assert "content-type" in allowed
