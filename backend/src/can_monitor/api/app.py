"""FastAPI application factory and `/api/v1` transport adapters."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from typing import Protocol

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

from can_monitor.api.schemas import (
    FilterRequest,
    SendFrameRequest,
    SessionCreateRequest,
    TransmissionMessageRequest,
    TransmissionPlanRequest,
    TxEnabledRequest,
)
from can_monitor.application.session import CanSessionManager
from can_monitor.config import Settings
from can_monitor.domain.models import CanInterfaceInfo, SendFrameCommand
from can_monitor.domain.validation import parse_hex_payload
from can_monitor.errors import CanMonitorError, NotFoundError
from can_monitor.infrastructure.discovery import LinuxCanInterfaceDiscoverer
from can_monitor.infrastructure.python_can_adapter import (
    CanBusAdapter,
    PythonCanSocketCanAdapter,
)

logger = logging.getLogger(__name__)


class InterfaceDiscoverer(Protocol):
    async def discover(self) -> list[CanInterfaceInfo]: ...


def _interface_wire(item: CanInterfaceInfo) -> dict[str, object]:
    return {
        "name": item.name,
        "channel": item.name,
        "kind": item.kind,
        "administratively_up": item.administratively_up,
        "operational_state": item.operational_state,
        "can_state": item.can_state,
        "bitrate": item.bitrate,
        "data_bitrate": item.data_bitrate,
        "fd_enabled": item.fd_enabled,
        "fd_capable": item.fd_capable,
        "mtu": item.mtu,
    }


def _problem(
    *, status: int, code: str, title: str, detail: str, instance: str
) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        media_type="application/problem+json",
        content={
            "type": f"urn:can-monitor:problem:{code}",
            "title": title,
            "status": status,
            "detail": detail,
            "instance": instance,
            "code": code,
        },
    )


def create_app(
    settings: Settings | None = None,
    *,
    adapter_factory: Callable[[], CanBusAdapter] | None = None,
    discoverer: InterfaceDiscoverer | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    logging.basicConfig(
        level=getattr(logging, settings.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    discoverer = discoverer or LinuxCanInterfaceDiscoverer()
    adapter_factory = adapter_factory or (
        lambda: PythonCanSocketCanAdapter(settings.acquisition_queue_size)
    )
    manager = CanSessionManager(
        adapter_factory,
        trace_buffer_size=settings.trace_buffer_size,
        client_queue_size=settings.client_queue_size,
        tx_enabled=settings.tx_enabled,
        virtual_tx_enabled=settings.virtual_tx_enabled,
        tx_rate_limit_per_second=settings.tx_rate_limit_per_second,
        recording_directory=settings.recording_directory,
        recording_queue_size=settings.recording_queue_size,
        recording_max_bytes=settings.recording_max_bytes,
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        yield
        await manager.shutdown()

    app = FastAPI(
        title="CAN Monitor API",
        version="1.0.0",
        lifespan=lifespan,
    )
    app.state.session_manager = manager
    app.state.interface_discoverer = discoverer
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(settings.cors_origins),
            allow_credentials=False,
            allow_methods=["GET", "POST", "PUT", "DELETE"],
            allow_headers=["Content-Type"],
        )

    @app.exception_handler(CanMonitorError)
    async def handle_app_error(request: Request, error: CanMonitorError) -> JSONResponse:
        logger.warning("%s: %s", error.code, error.detail)
        return _problem(
            status=error.status_code,
            code=error.code,
            title=error.title,
            detail=error.detail,
            instance=request.url.path,
        )

    @app.exception_handler(RequestValidationError)
    async def handle_validation(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        messages = []
        for item in error.errors()[:10]:
            location = ".".join(str(part) for part in item.get("loc", ()))
            message = str(item.get("msg", "Invalid value"))
            messages.append(f"{location}: {message}" if location else message)
        return _problem(
            status=422,
            code="validation_error",
            title="Request validation failed",
            detail="; ".join(messages) or "Request payload is invalid",
            instance=request.url.path,
        )

    @app.get("/api/v1/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/api/v1/can/interfaces")
    async def interfaces() -> dict[str, object]:
        items = await discoverer.discover()
        return {"interfaces": [_interface_wire(item) for item in items]}

    @app.get("/api/v1/can/tx-enabled")
    async def get_tx_enabled() -> dict[str, bool]:
        return {"enabled": manager.physical_tx_enabled}

    @app.put("/api/v1/can/tx-enabled")
    async def set_tx_enabled(payload: TxEnabledRequest) -> dict[str, bool]:
        enabled = await manager.set_physical_tx_enabled(payload.enabled)
        return {"enabled": enabled}

    @app.post("/api/v1/can/sessions", status_code=201)
    async def create_session(payload: SessionCreateRequest) -> dict[str, object]:
        available = await discoverer.discover()
        interface = next((item for item in available if item.name == payload.interface), None)
        if interface is None:
            raise NotFoundError(f"SocketCAN interface {payload.interface} was not found")
        session = await manager.create(interface, payload.fd, payload.filter.to_domain())
        return session.snapshot()

    @app.get("/api/v1/can/sessions/{session_id}")
    async def get_session(session_id: str) -> dict[str, object]:
        return manager.get(session_id).snapshot()

    @app.delete("/api/v1/can/sessions/{session_id}")
    async def delete_session(session_id: str) -> dict[str, object]:
        session = await manager.delete(session_id)
        return session.snapshot()

    @app.put("/api/v1/can/sessions/{session_id}/filters")
    async def update_filters(
        session_id: str, payload: FilterRequest
    ) -> dict[str, object]:
        session = manager.get(session_id)
        await session.update_filters(payload.to_domain())
        return session.snapshot()

    @app.get("/api/v1/can/sessions/{session_id}/timing")
    async def timing(session_id: str) -> dict[str, object]:
        session = manager.get(session_id)
        return {"statistics": session.timing_snapshot()}

    @app.post("/api/v1/can/sessions/{session_id}/frames", status_code=202)
    async def send_frame(
        session_id: str,
        payload: SendFrameRequest,
    ) -> dict[str, object]:
        session = manager.get(session_id)
        if payload.is_fd and not session.fd:
            from can_monitor.errors import InvalidRequestError

            raise InvalidRequestError("Session was not opened with CAN FD enabled")
        command = SendFrameCommand(
            can_id=payload.can_id,
            is_extended_id=payload.is_extended_id,
            is_fd=payload.is_fd,
            data=parse_hex_payload(payload.data_hex, is_fd=payload.is_fd),
        )
        await session.send(command)
        return {"status": "submitted"}

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions",
        status_code=201,
    )
    async def configure_transmission(
        session_id: str,
        payload: TransmissionPlanRequest,
    ) -> dict[str, object]:
        session = manager.get(session_id)
        plan = session.configure_transmission(
            tuple(message.to_domain() for message in payload.messages)
        )
        return plan.snapshot()

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/send-once",
        status_code=202,
    )
    async def send_transmission_once(
        session_id: str,
        payload: TransmissionPlanRequest,
    ) -> dict[str, object]:
        session = manager.get(session_id)
        plan = await session.send_transmission_once(
            tuple(message.to_domain() for message in payload.messages)
        )
        return plan.snapshot()

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/preview"
    )
    async def preview_transmission(
        session_id: str, payload: TransmissionMessageRequest
    ) -> dict[str, object]:
        session = manager.get(session_id)
        message = payload.to_domain()
        if message.is_fd and not session.fd:
            from can_monitor.errors import InvalidRequestError

            raise InvalidRequestError(
                "CAN FD messages require a session opened with CAN FD enabled"
            )
        command, crc_value = message.command()
        return {
            "message_id": message.message_id,
            "payload_hex": command.data.hex().upper(),
            "crc_value": crc_value,
        }

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/stop-all"
    )
    async def stop_all_transmissions(session_id: str) -> dict[str, object]:
        return await manager.get(session_id).stop_all_transmissions()

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/{plan_id}/start"
    )
    async def start_transmission(
        session_id: str, plan_id: str
    ) -> dict[str, object]:
        return await manager.get(session_id).start_transmission(plan_id)

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/{plan_id}/pause"
    )
    async def pause_transmission(
        session_id: str, plan_id: str
    ) -> dict[str, object]:
        return await manager.get(session_id).get_transmission(plan_id).pause()

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/{plan_id}/resume"
    )
    async def resume_transmission(
        session_id: str, plan_id: str
    ) -> dict[str, object]:
        return await manager.get(session_id).get_transmission(plan_id).resume()

    @app.post(
        "/api/v1/can/sessions/{session_id}/transmissions/{plan_id}/stop"
    )
    async def stop_transmission(
        session_id: str, plan_id: str
    ) -> dict[str, object]:
        return await manager.get(session_id).get_transmission(plan_id).stop()

    @app.get(
        "/api/v1/can/sessions/{session_id}/transmissions/{plan_id}"
    )
    async def get_transmission(
        session_id: str, plan_id: str
    ) -> dict[str, object]:
        return manager.get(session_id).get_transmission(plan_id).snapshot()

    @app.post(
        "/api/v1/can/sessions/{session_id}/recordings",
        status_code=201,
    )
    async def start_recording(session_id: str) -> dict[str, object]:
        return manager.start_recording(session_id).snapshot()

    @app.post(
        "/api/v1/can/sessions/{session_id}/recordings/{recording_id}/pause"
    )
    async def pause_recording(
        session_id: str, recording_id: str
    ) -> dict[str, object]:
        recording = await manager.pause_recording(session_id, recording_id)
        return recording.snapshot()

    @app.post(
        "/api/v1/can/sessions/{session_id}/recordings/{recording_id}/resume"
    )
    async def resume_recording(
        session_id: str, recording_id: str
    ) -> dict[str, object]:
        return manager.resume_recording(session_id, recording_id).snapshot()

    @app.post(
        "/api/v1/can/sessions/{session_id}/recordings/{recording_id}/stop"
    )
    async def stop_recording(
        session_id: str, recording_id: str
    ) -> dict[str, object]:
        recording = await manager.stop_recording(session_id, recording_id)
        return recording.snapshot()

    @app.get(
        "/api/v1/can/sessions/{session_id}/recordings/{recording_id}"
    )
    async def get_recording(
        session_id: str, recording_id: str
    ) -> dict[str, object]:
        return manager.get_recording(
            recording_id, session_id=session_id
        ).snapshot()

    @app.get("/api/v1/can/recordings/{recording_id}/download")
    async def download_recording(recording_id: str) -> FileResponse:
        recording = manager.get_recording(recording_id)
        path = recording.downloadable_path
        filename = recording.snapshot()["filename"]
        assert isinstance(filename, str)
        return FileResponse(
            path,
            media_type="application/octet-stream",
            filename=filename,
        )

    @app.websocket("/api/v1/can/sessions/{session_id}/stream")
    async def stream(websocket: WebSocket, session_id: str) -> None:
        origin = websocket.headers.get("origin")
        if settings.cors_origins and origin not in settings.cors_origins:
            await websocket.close(code=4403, reason="WebSocket origin not allowed")
            return
        if not settings.cors_origins and origin is not None:
            await websocket.close(code=4403, reason="WebSocket origin not allowed")
            return
        try:
            session = manager.get(session_id)
        except NotFoundError:
            await websocket.close(code=4404, reason="CAN session not found")
            return
        await websocket.accept()
        subscription = session.subscribe()
        await websocket.send_json(
            {"version": 1, "type": "hello", "session": session.snapshot()}
        )
        interval = settings.websocket_batch_interval_ms / 1000
        try:
            while True:
                first = await subscription.queue.get()
                if first is None:
                    await websocket.close(code=1000, reason="CAN session closed")
                    return
                if interval > 0:
                    await asyncio.sleep(interval)
                frames = [first]
                session_closed = False
                while len(frames) < settings.websocket_batch_size:
                    try:
                        item = subscription.queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break
                    if item is None:
                        session_closed = True
                        break
                    frames.append(item)
                await websocket.send_json(
                    {
                        "version": 1,
                        "type": "frames",
                        "frames": [frame.to_wire() for frame in frames],
                        "stream_dropped_frames": session.snapshot()[
                            "stream_dropped_frames"
                        ],
                        "adapter_dropped_frames": session.snapshot()[
                            "adapter_dropped_frames"
                        ],
                    }
                )
                if session_closed:
                    await websocket.close(code=1000, reason="CAN session closed")
                    return
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            session.unsubscribe(subscription.identifier)

    return app
