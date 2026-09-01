from __future__ import annotations

import asyncio
import io
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import can
import pytest
from fastapi.testclient import TestClient

from can_monitor.api.app import create_app
from can_monitor.application.recording import RecordingService, RecordingState
from can_monitor.application.session import CanSession
from can_monitor.config import Settings
from can_monitor.domain.models import (
    CanFrame,
    CanInterfaceInfo,
    Direction,
    FilterConfig,
    FilterMode,
)
from can_monitor.errors import ConflictError
from tests.fakes import FakeAdapter, FakeDiscoverer


def _frame(
    timestamp_ns: int,
    *,
    can_id: int = 0x123,
    extended: bool = False,
    direction: Direction = Direction.RX,
    data: bytes = b"\x01",
    dlc: int | None = None,
    fd: bool = False,
    remote: bool = False,
    error: bool = False,
) -> CanFrame:
    return CanFrame(
        capture_timestamp_ns=timestamp_ns,
        ingress_monotonic_ns=timestamp_ns,
        interface="vcan0",
        can_id=can_id,
        is_extended_id=extended,
        is_fd=fd,
        dlc=len(data) if dlc is None else dlc,
        data=data,
        direction=direction,
        is_remote_frame=remote,
        is_error_frame=error,
    )


def _recording(tmp_path: Path, **overrides) -> RecordingService:
    values = {
        "session_id": "session-1",
        "interface": "vcan0",
        "directory": tmp_path,
        "queue_size": 16,
        "max_bytes": 1024 * 1024,
        "now": lambda: datetime(2026, 9, 1, 15, 42, 18, tzinfo=timezone.utc),
    }
    values.update(overrides)
    return RecordingService(**values)


def test_trc_round_trip_preserves_classic_frames(tmp_path: Path) -> None:
    async def scenario() -> None:
        recording = _recording(tmp_path)
        recording.start()
        frames = [
            _frame(1_000_000_000, data=b"", dlc=0),
            _frame(
                1_100_000_000,
                can_id=0x1ABCDE,
                extended=True,
                direction=Direction.TX,
                data=bytes(range(8)),
                dlc=8,
            ),
        ]
        for frame in frames:
            recording.accept(frame)
        status = await recording.stop()

        assert status["state"] == "completed"
        assert status["recorded_frames"] == 2
        assert status["filename"] == (
            f"vcan0_2026-09-01_15-42-18_{recording.recording_id}.trc"
        )
        path = recording.downloadable_path
        assert path.suffix == ".trc"
        assert not (tmp_path / f"{path.name}.part").exists()

        messages = list(can.TRCReader(path))
        assert [message.arbitration_id for message in messages] == [0x123, 0x1ABCDE]
        assert [message.is_extended_id for message in messages] == [False, True]
        assert [message.is_rx for message in messages] == [True, False]
        assert [message.dlc for message in messages] == [0, 8]
        assert [bytes(message.data) for message in messages] == [b"", bytes(range(8))]
        assert messages[0].timestamp <= messages[1].timestamp

    asyncio.run(scenario())


def test_pause_resume_cycles_exclude_paused_frames(tmp_path: Path) -> None:
    async def scenario() -> None:
        recording = _recording(tmp_path)
        recording.start()
        recording.accept(_frame(1_000_000_000, data=b"\x01"))
        assert (await recording.pause())["state"] == "paused"
        recording.accept(_frame(2_000_000_000, data=b"\x02"))
        assert recording.resume()["state"] == "recording"
        recording.accept(_frame(3_000_000_000, data=b"\x03"))
        await recording.pause()
        recording.accept(_frame(4_000_000_000, data=b"\x04"))
        recording.resume()
        recording.accept(_frame(5_000_000_000, data=b"\x05"))
        await recording.stop()

        messages = list(can.TRCReader(recording.downloadable_path))
        assert [bytes(message.data) for message in messages] == [
            b"\x01",
            b"\x03",
            b"\x05",
        ]
        assert messages[1].timestamp - messages[0].timestamp == pytest.approx(2.0)
        assert messages[2].timestamp - messages[1].timestamp == pytest.approx(2.0)

    asyncio.run(scenario())


def test_invalid_state_transitions_are_rejected(tmp_path: Path) -> None:
    async def scenario() -> None:
        recording = _recording(tmp_path)
        with pytest.raises(ConflictError):
            await recording.pause()
        recording.start()
        with pytest.raises(ConflictError):
            recording.start()
        await recording.pause()
        with pytest.raises(ConflictError):
            await recording.pause()
        recording.resume()
        with pytest.raises(ConflictError):
            recording.resume()
        await recording.stop()
        with pytest.raises(ConflictError):
            await recording.stop()

    asyncio.run(scenario())


def test_unsupported_frames_are_visible_and_not_written(tmp_path: Path) -> None:
    async def scenario() -> None:
        recording = _recording(tmp_path)
        recording.start()
        recording.accept(_frame(1, fd=True))
        recording.accept(_frame(2, remote=True, data=b"", dlc=0))
        recording.accept(_frame(3, error=True))
        recording.accept(_frame(4, fd=True, remote=True))
        recording.accept(_frame(5, data=b"\xaa"))
        status = await recording.stop()

        assert status["recorded_frames"] == 1
        assert status["unsupported_frames"] == 4
        assert status["unsupported_can_fd"] == 2
        assert status["unsupported_remote_frames"] == 2
        assert status["unsupported_error_frames"] == 1
        assert status["degraded"] is True

    asyncio.run(scenario())


class _BlockingWriter:
    def __init__(self, path: str, entered: threading.Event, release: threading.Event):
        self._delegate = can.TRCWriter(path)
        self._entered = entered
        self._release = release

    @property
    def file(self):
        return self._delegate.file

    @property
    def header_written(self):
        return self._delegate.header_written

    def on_message_received(self, message: can.Message) -> None:
        self._entered.set()
        assert self._release.wait(timeout=2)
        self._delegate.on_message_received(message)

    def write_header(self, timestamp: float) -> None:
        self._delegate.write_header(timestamp)

    def stop(self) -> None:
        self._delegate.stop()


class _FailingWriter:
    def __init__(self, path: str, stopped: threading.Event):
        self._delegate = can.TRCWriter(path)
        self._stopped = stopped

    @property
    def file(self):
        return self._delegate.file

    @property
    def header_written(self):
        return self._delegate.header_written

    def on_message_received(self, message: can.Message) -> None:
        raise OSError("simulated disk write failure")

    def write_header(self, timestamp: float) -> None:
        self._delegate.write_header(timestamp)

    def stop(self) -> None:
        self._delegate.stop()
        self._stopped.set()


def test_full_queue_drops_without_blocking_acquisition(tmp_path: Path) -> None:
    async def scenario() -> None:
        entered = threading.Event()
        release = threading.Event()
        recording = _recording(
            tmp_path,
            queue_size=1,
            writer_factory=lambda path: _BlockingWriter(path, entered, release),
        )
        recording.start()
        recording.accept(_frame(1))
        assert await asyncio.to_thread(entered.wait, 1)
        recording.accept(_frame(2))
        before = time.monotonic()
        recording.accept(_frame(3))
        assert time.monotonic() - before < 0.05
        assert recording.snapshot()["dropped_frames"] == 1
        release.set()
        status = await recording.stop()
        assert status["state"] == "completed"
        assert status["recorded_frames"] == 2
        assert status["degraded"] is True

    asyncio.run(scenario())


def test_size_limit_keeps_partial_file_and_reports_error(tmp_path: Path) -> None:
    async def scenario() -> None:
        recording = _recording(tmp_path, max_bytes=1)
        recording.start()
        recording.accept(_frame(1_000_000_000))
        for _ in range(100):
            if recording.state is RecordingState.ERROR:
                break
            await asyncio.sleep(0.01)
        status = await recording.finalize_if_active()
        assert status["state"] == "error"
        assert "size limit" in str(status["error"])
        assert list(tmp_path.glob("*.trc")) == []
        assert len(list(tmp_path.glob("*.trc.part"))) == 1
        with pytest.raises(ConflictError):
            _ = recording.downloadable_path

    asyncio.run(scenario())


def test_worker_disk_failure_closes_writer_and_stays_partial(tmp_path: Path) -> None:
    async def scenario() -> None:
        stopped = threading.Event()
        recording = _recording(
            tmp_path,
            writer_factory=lambda path: _FailingWriter(path, stopped),
        )
        recording.start()
        recording.accept(_frame(1_000_000_000))
        for _ in range(100):
            if recording.state is RecordingState.ERROR:
                break
            await asyncio.sleep(0.01)
        status = await recording.finalize_if_active()
        assert status["state"] == "error"
        assert "simulated disk write failure" in str(status["error"])
        assert stopped.is_set()
        assert list(tmp_path.glob("*.trc")) == []
        assert len(list(tmp_path.glob("*.trc.part"))) == 1

    asyncio.run(scenario())


def test_filename_is_sanitized_and_cannot_escape_directory(tmp_path: Path) -> None:
    async def scenario() -> None:
        recording = _recording(tmp_path, interface="../../can0 evil")
        recording.start()
        status = await recording.stop()
        filename = status["filename"]
        assert isinstance(filename, str)
        assert "/" not in filename and "\\" not in filename
        assert recording.downloadable_path.parent == tmp_path.resolve()

    asyncio.run(scenario())


def test_pause_only_stops_recording_not_session_acquisition(tmp_path: Path) -> None:
    async def scenario() -> None:
        adapter = FakeAdapter()
        session = CanSession(
            "session-1",
            CanInterfaceInfo("vcan0", "vcan"),
            False,
            FilterConfig(FilterMode.ALL),
            adapter,
            trace_buffer_size=8,
            client_queue_size=8,
            tx_enabled=False,
            virtual_tx_enabled=True,
            physical_tx_token=None,
            tx_rate_limit_per_second=10,
            recording_directory=tmp_path,
        )
        await session.connect()
        subscription = session.subscribe()
        recording = session.start_recording()
        await recording.pause()
        await adapter.queue.put(_frame(2_000_000_000, data=b"\x22"))
        captured = await asyncio.wait_for(subscription.queue.get(), timeout=1)
        assert captured is not None and captured.frame.data == b"\x22"
        assert session.snapshot()["frames_received"] == 1
        assert recording.snapshot()["recorded_frames"] == 0
        recording.resume()
        await adapter.queue.put(_frame(3_000_000_000, data=b"\x33"))
        await asyncio.wait_for(subscription.queue.get(), timeout=1)
        await session.close()
        assert recording.snapshot()["state"] == "completed"
        assert recording.snapshot()["recorded_frames"] == 1

    asyncio.run(scenario())


def _api_settings(tmp_path: Path, **overrides) -> Settings:
    values = {
        "trace_buffer_size": 8,
        "client_queue_size": 8,
        "websocket_batch_size": 10,
        "websocket_batch_interval_ms": 1,
        "cors_origins": (),
        "recording_directory": tmp_path,
        "recording_queue_size": 8,
        "recording_max_bytes": 1024 * 1024,
    }
    values.update(overrides)
    return Settings(**values)


def test_recording_api_lifecycle_download_and_disconnect(tmp_path: Path) -> None:
    adapters: list[FakeAdapter] = []

    def factory() -> FakeAdapter:
        adapter = FakeAdapter()
        adapters.append(adapter)
        return adapter

    app = create_app(
        _api_settings(tmp_path),
        adapter_factory=factory,
        discoverer=FakeDiscoverer([CanInterfaceInfo("vcan0", "vcan")]),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
        ).json()
        base = f"/api/v1/can/sessions/{session['id']}/recordings"
        started = client.post(base)
        assert started.status_code == 201
        recording = started.json()
        recording_id = recording["recording_id"]
        assert client.post(base).status_code == 409
        assert client.get(
            f"/api/v1/can/recordings/{recording_id}/download"
        ).status_code == 409

        adapters[0].emit(_frame(1_000_000_000, data=b"\x01"))
        paused = client.post(f"{base}/{recording_id}/pause")
        assert paused.json()["state"] == "paused"
        adapters[0].emit(_frame(2_000_000_000, data=b"\x02"))
        assert client.post(f"{base}/{recording_id}/resume").json()["state"] == (
            "recording"
        )
        adapters[0].emit(_frame(3_000_000_000, data=b"\x03"))
        stopped = client.post(f"{base}/{recording_id}/stop")
        assert stopped.json()["state"] == "completed"
        assert stopped.json()["recorded_frames"] == 2
        status = client.get(f"{base}/{recording_id}")
        assert status.json()["filename"].endswith(".trc")
        download = client.get(f"/api/v1/can/recordings/{recording_id}/download")
        assert download.status_code == 200
        assert download.headers["content-disposition"].startswith("attachment;")
        assert len(list(can.TRCReader(io.StringIO(download.content.decode())))) == 2

        second = client.post(base).json()
        second_id = second["recording_id"]
        deleted = client.delete(f"/api/v1/can/sessions/{session['id']}")
        assert deleted.status_code == 200
        assert client.get(f"{base}/{second_id}").json()["state"] == "completed"
        assert client.get(
            f"/api/v1/can/recordings/{second_id}/download"
        ).status_code == 200


def test_can_fd_session_cannot_start_trc_recording(tmp_path: Path) -> None:
    app = create_app(
        _api_settings(tmp_path),
        adapter_factory=FakeAdapter,
        discoverer=FakeDiscoverer([CanInterfaceInfo("vcan0", "vcan")]),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={
                "interface": "vcan0",
                "fd": True,
                "filter": {"mode": "all", "ids": []},
            },
        ).json()
        response = client.post(
            f"/api/v1/can/sessions/{session['id']}/recordings"
        )
        assert response.status_code == 400
        assert "CAN FD" in response.json()["detail"]


def test_application_shutdown_finalizes_active_recording(tmp_path: Path) -> None:
    app = create_app(
        _api_settings(tmp_path),
        adapter_factory=FakeAdapter,
        discoverer=FakeDiscoverer([CanInterfaceInfo("vcan0", "vcan")]),
    )
    recording_id = ""
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
        ).json()
        recording_id = client.post(
            f"/api/v1/can/sessions/{session['id']}/recordings"
        ).json()["recording_id"]

    recording = app.state.session_manager.get_recording(recording_id)
    assert recording.snapshot()["state"] == "completed"
    assert recording.downloadable_path.is_file()
