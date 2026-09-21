from pathlib import Path
from urllib.parse import urlsplit

from httpx import Headers
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from can_monitor.api.app import create_app
from can_monitor.config import Settings
from can_monitor.domain.models import CanInterfaceInfo
from tests.fakes import FakeAdapter, FakeDiscoverer


@pytest.fixture
def web_build(tmp_path: Path) -> Path:
    directory = tmp_path / "web"
    directory.mkdir()
    (directory / "index.html").write_text("<html>local viewer</html>")
    (directory / "main.dart.js").write_text("window.localViewer = true;")
    (directory / "flutter_service_worker.js").write_text("// local worker")
    (directory / "canvaskit").mkdir()
    (directory / "canvaskit" / "canvaskit.wasm").write_bytes(b"\x00asm")
    (directory / "assets").mkdir()
    (directory / "assets" / "font.woff2").write_bytes(b"font")
    return directory


def _app(directory: Path | None = None, *, origins: tuple[str, ...] = ()):
    return create_app(
        Settings(frontend_directory=directory, cors_origins=origins),
        adapter_factory=FakeAdapter,
        discoverer=FakeDiscoverer([CanInterfaceInfo("vcan0", "vcan")]),
    )


def _stream_path(client: TestClient) -> str:
    session = client.post(
        "/api/v1/can/sessions",
        json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
    )
    assert session.status_code == 201
    return f"/api/v1/can/sessions/{session.json()['id']}/stream"


def test_web_build_and_api_are_served_together(web_build: Path) -> None:
    with TestClient(_app(web_build)) as client:
        for path, media_type in (
            ("/", "text/html"),
            ("/index.html", "text/html"),
            ("/main.dart.js", "javascript"),
            ("/flutter_service_worker.js", "javascript"),
            ("/canvaskit/canvaskit.wasm", "application/wasm"),
            ("/assets/font.woff2", "font/woff2"),
        ):
            response = client.get(path)
            assert response.status_code == 200, path
            assert media_type in response.headers["content-type"], path
            assert response.headers["cache-control"] == "no-cache"
        assert client.get("/api/v1/health").json() == {"status": "ok"}
        assert client.get("/openapi.json").status_code == 200
        assert client.get("/docs").status_code == 404
        assert client.get("/redoc").status_code == 404


def test_static_files_revalidate_after_a_release(web_build: Path) -> None:
    with TestClient(_app(web_build)) as client:
        response = client.get("/main.dart.js")
        etag = response.headers["etag"]
        unchanged = client.get("/main.dart.js", headers={"If-None-Match": etag})
        assert unchanged.status_code == 304
        assert unchanged.headers["cache-control"] == "no-cache"
        (web_build / "main.dart.js").write_text("window.localViewer = 'new release';")
        changed = client.get("/main.dart.js", headers={"If-None-Match": etag})
        assert changed.status_code == 200
        assert "new release" in changed.text


def test_unknown_assets_api_and_traversal_do_not_return_index(web_build: Path) -> None:
    (web_build.parent / "secret.txt").write_text("outside build")
    (web_build / "outside.txt").symlink_to(web_build.parent / "secret.txt")
    (web_build / "api").mkdir()
    (web_build / "api" / "unregistered").write_text("must not shadow API")
    with TestClient(_app(web_build)) as client:
        for path in (
            "/assets/missing.js",
            "/missing-route",
            "/api/v1/missing",
            "/api/unregistered",
            "/%2e%2e/secret.txt",
            "/outside.txt",
        ):
            response = client.get(path)
            assert response.status_code == 404, path
            assert "local viewer" not in response.text
            assert "outside build" not in response.text
        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect("/api/v1/missing-stream"):
                pass
        assert rejected.value.code == 4404


def test_backend_only_keeps_existing_docs_and_has_no_frontend() -> None:
    with TestClient(_app()) as client:
        assert client.get("/").status_code == 404
        assert client.get("/docs").status_code == 200
        assert client.get("/redoc").status_code == 200
        assert client.get("/api/v1/health").status_code == 200


def test_incomplete_web_build_fails_before_serving(tmp_path: Path) -> None:
    for directory in (tmp_path, tmp_path / "missing"):
        with pytest.raises(ValueError, match="CAN_MONITOR_FRONTEND_DIRECTORY"):
            _app(directory)


@pytest.mark.parametrize(
    ("url", "origin"),
    [
        ("ws://192.168.1.20:8000", "http://192.168.1.20:8000"),
        ("ws://jetson.local", "http://JETSON.LOCAL:80"),
        ("wss://jetson.local", "https://jetson.local:443"),
        ("ws://[::1]:8000", "http://[::1]:8000"),
    ],
)
@pytest.mark.parametrize("origins", [(), ("http://localhost:8080",)])
def test_websocket_same_origin_works_without_lan_allowlist(
    web_build: Path, url: str, origin: str, origins: tuple[str, ...]
) -> None:
    with TestClient(_app(web_build, origins=origins)) as client:
        path = _stream_path(client)
        parsed = urlsplit(url)
        # TestClient's transport cannot parse an IPv6 URL; the real ASGI Host
        # header still exercises IPv6 handling in our application.
        with client.websocket_connect(
            f"{parsed.scheme}://testserver" + path,
            headers={"origin": origin, "host": parsed.netloc},
        ) as ws:
            assert ws.receive_json()["type"] == "hello"


@pytest.mark.parametrize(
    "origin",
    [
        "http://foreign.example",
        "https://jetson.local:8000",
        "http://jetson.local:8001",
        "http://jetson.local:8000.evil.example",
        "http://jetson.local:8000/path",
        "http://jetson.local:8000/",
        "http://jetson.local:8000?",
        "http://jetson.local:8000#",
        "http://user@jetson.local:8000",
        "http://jetson.local:8000\\evil",
        " http://jetson.local:8000",
        "null",
        "*",
        "http://[::invalid",
        "http://jetson.local:99999",
    ],
)
def test_websocket_rejects_foreign_and_malformed_origins(origin: str) -> None:
    with TestClient(_app()) as client:
        path = _stream_path(client)
        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect(
                "ws://jetson.local:8000" + path, headers={"origin": origin}
            ):
                pass
        assert rejected.value.code == 4403


def test_websocket_ignores_forwarded_host_and_rejects_duplicate_origin() -> None:
    with TestClient(_app()) as client:
        path = _stream_path(client)
        for headers in (
            {"origin": "http://foreign.example", "x-forwarded-host": "foreign.example"},
            Headers([("origin", "http://jetson.local:8000"), ("origin", "http://foreign.example")]),
        ):
            with pytest.raises(WebSocketDisconnect) as rejected:
                with client.websocket_connect("ws://jetson.local:8000" + path, headers=headers):
                    pass
            assert rejected.value.code == 4403


def test_same_origin_support_does_not_expand_http_cors(web_build: Path) -> None:
    with TestClient(_app(web_build)) as client:
        response = client.get(
            "/api/v1/health", headers={"Origin": "http://foreign.example"}
        )
        assert "access-control-allow-origin" not in response.headers
