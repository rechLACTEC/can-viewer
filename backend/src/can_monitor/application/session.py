"""Single-session CAN acquisition, analysis, buffering, and fan-out service."""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
import uuid
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from can_monitor.application.recording import RecordingService, RecordingState
from can_monitor.application.transmission import (
    TransmissionMessage,
    TransmissionPlan,
    TransmissionPlanState,
)
from can_monitor.domain.models import (
    CanInterfaceInfo,
    CapturedFrame,
    FilterConfig,
    SendFrameCommand,
    SessionState,
)
from can_monitor.domain.timing import TimingAnalyzer
from can_monitor.errors import (
    ConflictError,
    InvalidRequestError,
    NotFoundError,
    RateLimitError,
    TransmissionAuthorizationError,
    TransmissionDisabledError,
)
from can_monitor.infrastructure.python_can_adapter import CanBusAdapter

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class Subscription:
    identifier: str
    queue: asyncio.Queue[CapturedFrame | None]


class CanSession:
    def __init__(
        self,
        session_id: str,
        interface: CanInterfaceInfo,
        fd: bool,
        filters: FilterConfig,
        adapter: CanBusAdapter,
        *,
        trace_buffer_size: int,
        client_queue_size: int,
        tx_enabled: bool,
        virtual_tx_enabled: bool,
        physical_tx_token: str | None,
        tx_rate_limit_per_second: int,
        recording_directory: Path = Path("/data/recordings"),
        recording_queue_size: int = 8192,
        recording_max_bytes: int = 256 * 1024 * 1024,
    ) -> None:
        self.id = session_id
        self.interface = interface
        self.fd = fd
        self.filters = filters
        self.filter_revision = 1
        self.state = SessionState.DISCONNECTED
        self.error: str | None = None
        self._adapter = adapter
        self._trace: deque[CapturedFrame] = deque(maxlen=trace_buffer_size)
        self._client_queue_size = client_queue_size
        self._subscribers: dict[str, asyncio.Queue[CapturedFrame | None]] = {}
        self._analyzer = TimingAnalyzer()
        self._sequence = 0
        self._stream_dropped_frames = 0
        self._task: asyncio.Task[None] | None = None
        self._filter_lock = asyncio.Lock()
        self._tx_enabled = tx_enabled
        self._virtual_tx_enabled = virtual_tx_enabled
        self._physical_tx_token = physical_tx_token
        self._tx_rate_limit_per_second = tx_rate_limit_per_second
        self._tx_timestamps: deque[float] = deque()
        self._tx_lock = asyncio.Lock()
        self._subscribers_closed = False
        self._recording_directory = recording_directory
        self._recording_queue_size = recording_queue_size
        self._recording_max_bytes = recording_max_bytes
        self._active_recording: RecordingService | None = None
        self._transmission_plan: TransmissionPlan | None = None

    async def connect(self) -> None:
        self.state = SessionState.CONNECTING
        try:
            await self._adapter.open(self.interface.name, self.fd, self.filters)
        except Exception:
            self.state = SessionState.ERROR
            await self._close_adapter()
            raise
        self.state = SessionState.CONNECTED
        self._task = asyncio.create_task(self._acquire(), name=f"can-session-{self.id}")

    async def _acquire(self) -> None:
        try:
            async for frame in self._adapter.frames():
                # This lock is the application-level filter revision boundary.
                # Frames processed before an update retain the old revision; frames
                # processed after set_filters returns receive the new revision.
                async with self._filter_lock:
                    self._sequence += 1
                    captured = CapturedFrame(
                        sequence=self._sequence,
                        filter_revision=self.filter_revision,
                        frame=frame,
                    )
                    if self._active_recording is not None:
                        self._active_recording.accept(frame)
                    self._analyzer.observe(frame)
                    self._trace.append(captured)
                    for queue in tuple(self._subscribers.values()):
                        if queue.full():
                            try:
                                queue.get_nowait()
                            except asyncio.QueueEmpty:
                                pass
                            self._stream_dropped_frames += 1
                        queue.put_nowait(captured)
            if self.state is SessionState.CONNECTED:
                self.error = "CAN acquisition stream ended unexpectedly"
                self.state = SessionState.ERROR
        except asyncio.CancelledError:
            raise
        except Exception as error:  # adapter failure must become observable state
            logger.exception("CAN acquisition failed for session %s", self.id)
            self.error = str(error)
            self.state = SessionState.ERROR
        finally:
            await self._finalize_active_recording()
            await self._close_adapter()
            self._signal_subscribers_closed()

    async def update_filters(self, filters: FilterConfig) -> None:
        async with self._filter_lock:
            await self._adapter.set_filters(filters)
            self.filters = filters
            self.filter_revision += 1

    async def send(
        self, command: SendFrameCommand, authorization_token: str | None = None
    ) -> None:
        virtual = self.interface.kind == "vcan"
        if not self._tx_enabled and not (virtual and self._virtual_tx_enabled):
            raise TransmissionDisabledError(
                "Transmission on physical CAN interfaces is disabled; set "
                "CAN_MONITOR_TX_ENABLED=true only in an authorized environment"
            )
        if not virtual:
            expected = self._physical_tx_token
            if (
                expected is None
                or authorization_token is None
                or not secrets.compare_digest(authorization_token, expected)
            ):
                raise TransmissionAuthorizationError(
                    "A valid physical CAN transmission token is required"
                )
        async with self._tx_lock:
            now = time.monotonic()
            cutoff = now - 1.0
            while self._tx_timestamps and self._tx_timestamps[0] <= cutoff:
                self._tx_timestamps.popleft()
            if len(self._tx_timestamps) >= self._tx_rate_limit_per_second:
                raise RateLimitError(
                    "The configured CAN transmission rate limit was exceeded"
                )
            logger.info(
                "Submitting manual CAN frame session=%s interface=%s id=0x%X "
                "extended=%s fd=%s bytes=%d",
                self.id,
                self.interface.name,
                command.can_id,
                command.is_extended_id,
                command.is_fd,
                len(command.data),
            )
            try:
                await self._adapter.send(command)
            except Exception:
                logger.exception(
                    "Manual CAN frame submission failed session=%s interface=%s id=0x%X",
                    self.id,
                    self.interface.name,
                    command.can_id,
                )
                raise
            self._tx_timestamps.append(now)
            logger.info(
                "Manual CAN frame submitted session=%s interface=%s id=0x%X",
                self.id,
                self.interface.name,
                command.can_id,
            )

    def subscribe(self) -> Subscription:
        identifier = str(uuid.uuid4())
        queue: asyncio.Queue[CapturedFrame | None] = asyncio.Queue(
            maxsize=self._client_queue_size
        )
        self._subscribers[identifier] = queue
        if self._subscribers_closed:
            queue.put_nowait(None)
        return Subscription(identifier, queue)

    def unsubscribe(self, identifier: str) -> None:
        self._subscribers.pop(identifier, None)

    async def close(self) -> None:
        if self.state is SessionState.DISCONNECTED:
            self._signal_subscribers_closed()
            return
        if self.state is not SessionState.ERROR:
            self.state = SessionState.DISCONNECTING
        await self._finalize_active_recording()
        await self.stop_all_transmissions()
        task = self._task
        self._task = None
        if task is not None and task is not asyncio.current_task():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await self._close_adapter()
        self._signal_subscribers_closed()
        if self.state is not SessionState.ERROR:
            self.state = SessionState.DISCONNECTED

    def start_recording(self) -> RecordingService:
        if self.state is not SessionState.CONNECTED:
            raise ConflictError("TRC recording requires a connected CAN session")
        if self.fd:
            raise InvalidRequestError(
                "TRC recording is not available for CAN FD sessions because "
                "python-can TRCWriter 4.6.1 does not support CAN FD"
            )
        current = self._active_recording
        if current is not None and current.state in {
            RecordingState.RECORDING,
            RecordingState.PAUSED,
            RecordingState.FINALIZING,
        }:
            raise ConflictError("This CAN session already has an active recording")
        recording = RecordingService(
            session_id=self.id,
            interface=self.interface.name,
            directory=self._recording_directory,
            queue_size=self._recording_queue_size,
            max_bytes=self._recording_max_bytes,
        )
        recording.start()
        self._active_recording = recording
        return recording

    async def _finalize_active_recording(self) -> None:
        recording = self._active_recording
        if recording is not None:
            await recording.finalize_if_active()

    def configure_transmission(
        self,
        messages: tuple[TransmissionMessage, ...],
        authorization_token: str | None,
    ) -> TransmissionPlan:
        if self.state is not SessionState.CONNECTED:
            raise ConflictError("Transmission requires a connected CAN session")
        current = self._transmission_plan
        if current is not None and current.state in {
            TransmissionPlanState.RUNNING,
            TransmissionPlanState.PAUSED,
        }:
            raise ConflictError("Stop the active transmission before reconfiguring")
        if any(message.is_fd and not self.fd for message in messages):
            raise InvalidRequestError(
                "CAN FD messages require a session opened with CAN FD enabled"
            )
        self._transmission_plan = TransmissionPlan(
            session_id=self.id,
            interface=self.interface.name,
            messages=messages,
            sender=self.send,
            authorization_token=authorization_token,
            bitrate=self.interface.bitrate,
        )
        return self._transmission_plan

    def get_transmission(self, plan_id: str) -> TransmissionPlan:
        plan = self._transmission_plan
        if plan is None or plan.plan_id != plan_id:
            raise NotFoundError(f"Transmission plan {plan_id} was not found")
        return plan

    async def send_transmission_once(
        self,
        messages: tuple[TransmissionMessage, ...],
        authorization_token: str | None,
    ) -> TransmissionPlan:
        if any(message.is_fd and not self.fd for message in messages):
            raise InvalidRequestError(
                "CAN FD messages require a session opened with CAN FD enabled"
            )
        plan = TransmissionPlan(
            session_id=self.id,
            interface=self.interface.name,
            messages=messages,
            sender=self.send,
            authorization_token=authorization_token,
            bitrate=self.interface.bitrate,
        )
        await plan.send_once()
        return plan

    async def stop_all_transmissions(self) -> dict[str, object]:
        plan = self._transmission_plan
        if plan is None:
            return {"stopped": 0}
        if plan.state in {
            TransmissionPlanState.RUNNING,
            TransmissionPlanState.PAUSED,
        }:
            await plan.stop()
            return {"stopped": 1, "plan": plan.snapshot()}
        return {"stopped": 0, "plan": plan.snapshot()}

    async def _close_adapter(self) -> None:
        try:
            await self._adapter.close()
        except Exception as error:
            logger.exception("CAN adapter cleanup failed for session %s", self.id)
            cleanup_detail = f"CAN adapter cleanup failed: {error}"
            self.error = (
                f"{self.error}; {cleanup_detail}" if self.error else cleanup_detail
            )
            self.state = SessionState.ERROR

    def _signal_subscribers_closed(self) -> None:
        if self._subscribers_closed:
            return
        self._subscribers_closed = True
        for queue in tuple(self._subscribers.values()):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(None)

    def snapshot(self) -> dict[str, object]:
        return {
            "id": self.id,
            "interface": self.interface.name,
            "interface_kind": self.interface.kind,
            "fd": self.fd,
            "state": self.state.value,
            "error": self.error,
            "filter": {
                "mode": self.filters.mode.value,
                "ids": [
                    {
                        "can_id": item.can_id,
                        "is_extended_id": item.is_extended_id,
                    }
                    for item in self.filters.ids
                ],
            },
            "filter_revision": self.filter_revision,
            "filter_placement": "unknown",
            "frames_received": self._sequence,
            "adapter_dropped_frames": self._adapter.dropped_frames,
            "stream_dropped_frames": self._stream_dropped_frames,
            "trace_size": len(self._trace),
        }

    def timing_snapshot(self) -> list[dict[str, object]]:
        return self._analyzer.snapshot()


AdapterFactory = Callable[[], CanBusAdapter]


class CanSessionManager:
    def __init__(
        self,
        adapter_factory: AdapterFactory,
        *,
        trace_buffer_size: int,
        client_queue_size: int,
        tx_enabled: bool,
        virtual_tx_enabled: bool,
        physical_tx_token: str | None,
        tx_rate_limit_per_second: int,
        recording_directory: Path = Path("/data/recordings"),
        recording_queue_size: int = 8192,
        recording_max_bytes: int = 256 * 1024 * 1024,
    ) -> None:
        self._adapter_factory = adapter_factory
        self._trace_buffer_size = trace_buffer_size
        self._client_queue_size = client_queue_size
        self._tx_enabled = tx_enabled
        self._virtual_tx_enabled = virtual_tx_enabled
        self._physical_tx_token = physical_tx_token
        self._tx_rate_limit_per_second = tx_rate_limit_per_second
        self._recording_directory = recording_directory
        self._recording_queue_size = recording_queue_size
        self._recording_max_bytes = recording_max_bytes
        self._session: CanSession | None = None
        self._recordings: dict[str, RecordingService] = {}
        self._lock = asyncio.Lock()

    async def create(
        self,
        interface: CanInterfaceInfo,
        fd: bool,
        filters: FilterConfig,
    ) -> CanSession:
        async with self._lock:
            if self._session is not None and self._session.state is not SessionState.DISCONNECTED:
                raise ConflictError("Only one active CAN session is supported in the MVP")
            session = CanSession(
                str(uuid.uuid4()),
                interface,
                fd,
                filters,
                self._adapter_factory(),
                trace_buffer_size=self._trace_buffer_size,
                client_queue_size=self._client_queue_size,
                tx_enabled=self._tx_enabled,
                virtual_tx_enabled=self._virtual_tx_enabled,
                physical_tx_token=self._physical_tx_token,
                tx_rate_limit_per_second=self._tx_rate_limit_per_second,
                recording_directory=self._recording_directory,
                recording_queue_size=self._recording_queue_size,
                recording_max_bytes=self._recording_max_bytes,
            )
            await session.connect()
            self._session = session
            return session

    def start_recording(self, session_id: str) -> RecordingService:
        recording = self.get(session_id).start_recording()
        self._recordings[recording.recording_id] = recording
        return recording

    def get_recording(
        self, recording_id: str, *, session_id: str | None = None
    ) -> RecordingService:
        recording = self._recordings.get(recording_id)
        if recording is None or (
            session_id is not None and recording.session_id != session_id
        ):
            raise NotFoundError(f"CAN recording {recording_id} was not found")
        return recording

    async def pause_recording(
        self, session_id: str, recording_id: str
    ) -> RecordingService:
        recording = self.get_recording(recording_id, session_id=session_id)
        await recording.pause()
        return recording

    def resume_recording(
        self, session_id: str, recording_id: str
    ) -> RecordingService:
        recording = self.get_recording(recording_id, session_id=session_id)
        recording.resume()
        return recording

    async def stop_recording(
        self, session_id: str, recording_id: str
    ) -> RecordingService:
        recording = self.get_recording(recording_id, session_id=session_id)
        await recording.stop()
        return recording

    def get(self, session_id: str) -> CanSession:
        if self._session is None or self._session.id != session_id:
            raise NotFoundError(f"CAN session {session_id} was not found")
        return self._session

    async def delete(self, session_id: str) -> CanSession:
        async with self._lock:
            session = self.get(session_id)
            await session.close()
            self._session = None
            return session

    async def shutdown(self) -> None:
        if self._session is not None:
            await self._session.close()
            self._session = None
