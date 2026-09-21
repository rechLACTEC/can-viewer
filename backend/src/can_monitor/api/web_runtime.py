"""Local web assets and origin checks for the optional same-origin deployment."""

from __future__ import annotations

from urllib.parse import urlsplit

from fastapi import WebSocket
from starlette.exceptions import HTTPException
from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Receive, Scope, Send


def _http_origin(value: str) -> tuple[str, str, int] | None:
    """Compare serialized HTTP origins without paths, user info or parser repairs."""
    if any(character.isspace() or ord(character) < 32 for character in value):
        return None
    if any(character in value for character in ("\\", "?", "#")):
        return None
    try:
        parsed = urlsplit(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path
            or parsed.netloc.endswith(":")
        ):
            return None
        port = parsed.port
        if port == 0:
            return None
        return parsed.scheme, parsed.hostname.lower(), port or (
            443 if parsed.scheme == "https" else 80
        )
    except ValueError:
        return None


def websocket_origin_allowed(websocket: WebSocket, allowed: tuple[str, ...]) -> bool:
    origins = websocket.headers.getlist("origin")
    if not origins:
        # Preserve the existing non-browser client policy.
        return not allowed
    if len(origins) != 1:
        return False
    origin = _http_origin(origins[0])
    if origin is None:
        return False
    if any(origin == _http_origin(item) for item in allowed):
        return True
    if len(websocket.headers.getlist("host")) != 1:
        return False
    request_url = websocket.url
    scheme = {"ws": "http", "wss": "https"}.get(request_url.scheme)
    if scheme is None:
        return False
    # Starlette uses the request Host; do not trust forwarded-host/origin headers.
    return origin == _http_origin(f"{scheme}://{request_url.netloc}")


class FrontendStaticFiles(StaticFiles):
    """Serve a prepared Flutter build without concealing missing API/assets."""

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "websocket":
            await send({"type": "websocket.close", "code": 4404})
            return
        await super().__call__(scope, receive, send)

    async def get_response(self, path: str, scope: Scope) -> Response:
        if path.split("/", 1)[0] in {"api", "docs", "redoc", "openapi.json"}:
            raise HTTPException(status_code=404)
        response = await super().get_response(path, scope)
        # Flutter output names are stable between releases. Revalidate every asset,
        # including bootstrap/service worker files, instead of retaining stale code.
        response.headers["Cache-Control"] = "no-cache"
        return response
