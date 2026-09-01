"""Bounded, asynchronous-to-acquisition TRC recording service."""

from __future__ import annotations

import asyncio
import logging
import os
import queue
import re
import shutil
import threading
import uuid
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import StrEnum
from pathlib import Path
from typing import Protocol

import can

from can_monitor.domain.models import CanFrame, Direction
from can_monitor.errors import ConflictError, RecordingStorageError

logger = logging.getLogger(__name__)

_MIN_FREE_BYTES = 1024 * 1024
_DISK_CHECK_INTERVAL = 128


class RecordingState(StrEnum):
    IDLE = "idle"
    RECORDING = "recording"
    PAUSED = "paused"
    FINALIZING = "finalizing"
    COMPLETED = "completed"
    ERROR = "error"


class TrcWriter(Protocol):
    file: object
    header_written: bool

    def on_message_received(self, message: can.Message) -> None: ...

    def write_header(self, timestamp: float) -> None: ...

    def stop(self) -> None: ...


WriterFactory = Callable[[str], TrcWriter]
ReaderFactory = Callable[[str], Iterator[can.Message]]


@dataclass(slots=True)
class _Barrier:
    reached: threading.Event


@dataclass(slots=True)
class _Stop:
    pass


_QueueItem = CanFrame | _Barrier | _Stop


class RecordingService:
    """Owns one recording, its bounded queue, writer thread, and state."""

    def __init__(
        self,
        *,
        session_id: str,
        interface: str,
        directory: Path,
        queue_size: int,
        max_bytes: int,
        writer_factory: WriterFactory = can.TRCWriter,
        reader_factory: ReaderFactory = can.TRCReader,
        now: Callable[[], datetime] | None = None,
    ) -> None:
        self.recording_id = str(uuid.uuid4())
        self.session_id = session_id
        self.interface = interface
        self.state = RecordingState.IDLE
        self.started_at: datetime | None = None
        self.completed_at: datetime | None = None
        self.recorded_frames = 0
        self.unsupported_frames = 0
        self.unsupported_can_fd = 0
        self.unsupported_remote_frames = 0
        self.unsupported_error_frames = 0
        self.dropped_frames = 0
        self.error: str | None = None

        self._directory = directory.resolve()
        self._queue: queue.Queue[_QueueItem] = queue.Queue(maxsize=queue_size)
        self._max_bytes = max_bytes
        self._writer_factory = writer_factory
        self._reader_factory = reader_factory
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()
        self._worker_done = threading.Event()
        self._thread: threading.Thread | None = None
        self._writer: TrcWriter | None = None
        self._part_path: Path | None = None
        self._final_path: Path | None = None
        self._filename: str | None = None

    def start(self) -> dict[str, object]:
        with self._lock:
            if self.state is not RecordingState.IDLE:
                raise ConflictError("Recording has already been started")
            self.started_at = self._now()
            try:
                self._prepare_storage()
                assert self._part_path is not None
                self._writer = self._writer_factory(str(self._part_path))
            except Exception as error:
                self.state = RecordingState.ERROR
                self.error = f"Could not initialize TRC recording: {error}"
                raise RecordingStorageError(self.error) from error
            self.state = RecordingState.RECORDING
            self._thread = threading.Thread(
                target=self._worker_main,
                name=f"trc-recording-{self.recording_id}",
                daemon=True,
            )
            self._thread.start()
        return self.snapshot()

    def accept(self, frame: CanFrame) -> None:
        """Non-blocking acquisition-path handoff."""
        with self._lock:
            if self.state is not RecordingState.RECORDING:
                return
            unsupported = False
            if frame.is_fd:
                self.unsupported_can_fd += 1
                unsupported = True
            if frame.is_remote_frame:
                self.unsupported_remote_frames += 1
                unsupported = True
            if frame.is_error_frame:
                self.unsupported_error_frames += 1
                unsupported = True
            if unsupported:
                self.unsupported_frames += 1
                return
            try:
                self._queue.put_nowait(frame)
            except queue.Full:
                self.dropped_frames += 1

    async def pause(self) -> dict[str, object]:
        with self._lock:
            if self.state is not RecordingState.RECORDING:
                raise ConflictError("Only an active recording can be paused")
            self.state = RecordingState.PAUSED
            barrier = _Barrier(threading.Event())
        await asyncio.to_thread(self._put_control, barrier)
        await asyncio.to_thread(barrier.reached.wait)
        return self.snapshot()

    def resume(self) -> dict[str, object]:
        with self._lock:
            if self.state is not RecordingState.PAUSED:
                raise ConflictError("Only a paused recording can be resumed")
            self.state = RecordingState.RECORDING
        return self.snapshot()

    async def stop(self) -> dict[str, object]:
        with self._lock:
            if self.state not in {
                RecordingState.RECORDING,
                RecordingState.PAUSED,
            }:
                raise ConflictError("Only a recording or paused recording can be stopped")
            self.state = RecordingState.FINALIZING
            marker = _Stop()
        await asyncio.to_thread(self._put_control, marker)
        await asyncio.to_thread(self._worker_done.wait)
        return self.snapshot()

    async def finalize_if_active(self) -> dict[str, object]:
        with self._lock:
            active = self.state in {
                RecordingState.RECORDING,
                RecordingState.PAUSED,
            }
        if active:
            return await self.stop()
        if self.state is RecordingState.FINALIZING:
            await asyncio.to_thread(self._worker_done.wait)
        return self.snapshot()

    @property
    def downloadable_path(self) -> Path:
        with self._lock:
            if self.state is not RecordingState.COMPLETED or self._final_path is None:
                raise ConflictError("Recording is not finalized and cannot be downloaded")
            path = self._final_path
        if not path.is_file():
            raise RecordingStorageError("Finalized TRC file is no longer available")
        return path

    def snapshot(self) -> dict[str, object]:
        with self._lock:
            state = self.state
            part_path = self._part_path
            final_path = self._final_path
            path = final_path if state is RecordingState.COMPLETED else part_path
            snapshot = {
                "state": state.value,
                "recording_id": self.recording_id,
                "session_id": self.session_id,
                "interface": self.interface,
                "started_at": self.started_at.isoformat()
                if self.started_at is not None
                else None,
                "completed_at": self.completed_at.isoformat()
                if self.completed_at is not None
                else None,
                "recorded_frames": self.recorded_frames,
                "unsupported_frames": self.unsupported_frames,
                "unsupported_can_fd": self.unsupported_can_fd,
                "unsupported_remote_frames": self.unsupported_remote_frames,
                "unsupported_error_frames": self.unsupported_error_frames,
                "dropped_frames": self.dropped_frames,
                "degraded": self.unsupported_frames > 0 or self.dropped_frames > 0,
                "filename": self._filename,
                "error": self.error,
            }
        try:
            size_bytes = path.stat().st_size if path is not None else 0
        except OSError:
            size_bytes = 0
        snapshot["size_bytes"] = size_bytes
        return snapshot

    def _prepare_storage(self) -> None:
        self._directory.mkdir(parents=True, exist_ok=True)
        if not self._directory.is_dir():
            raise OSError("recording path is not a directory")
        if shutil.disk_usage(self._directory).free <= _MIN_FREE_BYTES:
            raise OSError("insufficient free disk space")
        assert self.started_at is not None
        safe_interface = re.sub(r"[^A-Za-z0-9_.-]", "_", self.interface)
        stamp = self.started_at.astimezone(timezone.utc).strftime("%Y-%m-%d_%H-%M-%S")
        self._filename = f"{safe_interface}_{stamp}_{self.recording_id}.trc"
        self._final_path = self._directory / self._filename
        self._part_path = self._directory / f"{self._filename}.part"
        for candidate in (self._part_path, self._final_path):
            if candidate.parent.resolve() != self._directory:
                raise OSError("unsafe recording path")
            if candidate.exists():
                raise FileExistsError(candidate.name)

    def _put_control(self, item: _Barrier | _Stop) -> None:
        while not self._worker_done.is_set():
            try:
                self._queue.put(item, timeout=0.1)
                return
            except queue.Full:
                continue
        if isinstance(item, _Barrier):
            item.reached.set()

    def _worker_main(self) -> None:
        normal_stop = False
        try:
            while True:
                item = self._queue.get()
                try:
                    if isinstance(item, _Barrier):
                        item.reached.set()
                        continue
                    if isinstance(item, _Stop):
                        normal_stop = True
                        break
                    self._write_frame(item)
                finally:
                    self._queue.task_done()
        except Exception as error:
            logger.exception("TRC recording worker failed: %s", self.recording_id)
            self._set_error(f"TRC recording failed: {error}")
        finally:
            self._finalize_writer(normal_stop)
            self._release_pending_controls()
            self._worker_done.set()

    def _write_frame(self, frame: CanFrame) -> None:
        writer = self._writer
        if writer is None:
            raise RuntimeError("TRC writer is not initialized")
        message = can.Message(
            timestamp=frame.capture_timestamp_ns / 1_000_000_000,
            arbitration_id=frame.can_id,
            is_extended_id=frame.is_extended_id,
            is_fd=False,
            dlc=frame.dlc,
            data=frame.data,
            is_rx=frame.direction is Direction.RX,
            channel=frame.interface,
            check=True,
        )
        writer.on_message_received(message)
        with self._lock:
            self.recorded_frames += 1
            count = self.recorded_frames
        file_object = writer.file
        if hasattr(file_object, "flush"):
            file_object.flush()
        size = file_object.tell() if hasattr(file_object, "tell") else 0
        if size > self._max_bytes:
            raise OSError(
                f"recording size limit of {self._max_bytes} bytes was exceeded"
            )
        if count % _DISK_CHECK_INTERVAL == 0:
            if shutil.disk_usage(self._directory).free <= _MIN_FREE_BYTES:
                raise OSError("insufficient free disk space")

    def _finalize_writer(self, normal_stop: bool) -> None:
        writer = self._writer
        self._writer = None
        if writer is None:
            self._set_error("TRC writer was not initialized")
            return
        try:
            if normal_stop and not writer.header_written:
                assert self.started_at is not None
                writer.write_header(self.started_at.timestamp())
            writer.stop()
        except Exception as error:
            self._set_error(f"Could not close TRC writer: {error}")
            normal_stop = False
        if not normal_stop or self.state is RecordingState.ERROR:
            return
        try:
            assert self._part_path is not None and self._final_path is not None
            parsed_frames = sum(1 for _ in self._reader_factory(str(self._part_path)))
            if parsed_frames != self.recorded_frames:
                raise ValueError(
                    f"TRC validation read {parsed_frames} of "
                    f"{self.recorded_frames} recorded frames"
                )
            os.replace(self._part_path, self._final_path)
            with self._lock:
                self.completed_at = self._now()
                self.state = RecordingState.COMPLETED
        except Exception as error:
            self._set_error(f"Could not validate or finalize TRC file: {error}")

    def _set_error(self, detail: str) -> None:
        with self._lock:
            self.error = detail
            self.state = RecordingState.ERROR

    def _release_pending_controls(self) -> None:
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                return
            try:
                if isinstance(item, _Barrier):
                    item.reached.set()
            finally:
                self._queue.task_done()
