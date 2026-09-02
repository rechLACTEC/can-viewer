"""Lifecycle-controlled multi-message CAN transmission scheduler."""

from __future__ import annotations

import asyncio
import heapq
import math
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import StrEnum

from can_monitor.domain.crc import CrcInsertion, insert_crc
from can_monitor.domain.models import SendFrameCommand
from can_monitor.errors import ConflictError, InvalidRequestError


class TransmissionMode(StrEnum):
    SINGLE = "single"
    CYCLIC = "cyclic"


class TransmissionPlanState(StrEnum):
    STOPPED = "stopped"
    RUNNING = "running"
    PAUSED = "paused"
    ERROR = "error"


@dataclass(frozen=True, slots=True)
class TransmissionMessage:
    message_id: str
    enabled: bool
    can_id: int
    is_extended_id: bool
    is_fd: bool
    payload: bytes
    mode: TransmissionMode
    period_ms: float | None = None
    crc: CrcInsertion | None = None

    @property
    def frequency_hz(self) -> float | None:
        return 1000.0 / self.period_ms if self.period_ms is not None else None

    def command(self) -> tuple[SendFrameCommand, int | None]:
        payload = self.payload
        crc_value = None
        if self.crc is not None:
            payload, crc_value = insert_crc(payload, self.crc)
        return (
            SendFrameCommand(
                can_id=self.can_id,
                is_extended_id=self.is_extended_id,
                is_fd=self.is_fd,
                data=payload,
            ),
            crc_value,
        )


@dataclass(slots=True)
class MessageTelemetry:
    sent_frames: int = 0
    send_errors: int = 0
    deadline_misses: int = 0
    last_transmission: datetime | None = None
    last_error: str | None = None
    last_crc: int | None = None
    state: str = "stopped"


Sender = Callable[[SendFrameCommand], Awaitable[None]]


class TransmissionPlan:
    def __init__(
        self,
        *,
        session_id: str,
        interface: str,
        messages: tuple[TransmissionMessage, ...],
        sender: Sender,
        bitrate: int | None = None,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        if not messages:
            raise InvalidRequestError("At least one transmission message is required")
        if not any(message.enabled for message in messages):
            raise InvalidRequestError("At least one transmission message must be enabled")
        self.plan_id = str(uuid.uuid4())
        self.session_id = session_id
        self.interface = interface
        self.messages = messages
        self.state = TransmissionPlanState.STOPPED
        self._sender = sender
        self._bitrate = bitrate
        self._monotonic = monotonic
        self._wake = asyncio.Event()
        self._send_lock = asyncio.Lock()
        self._task: asyncio.Task[None] | None = None
        self._telemetry = {
            message.message_id: MessageTelemetry() for message in messages
        }

    def start(self) -> dict[str, object]:
        if self.state is not TransmissionPlanState.STOPPED or self._task is not None:
            raise ConflictError("Transmission plan has already been started")
        self.state = TransmissionPlanState.RUNNING
        self._task = asyncio.create_task(
            self._run(), name=f"can-transmission-{self.plan_id}"
        )
        return self.snapshot()

    async def pause(self) -> dict[str, object]:
        async with self._send_lock:
            if self.state is not TransmissionPlanState.RUNNING:
                raise ConflictError("Only a running transmission can be paused")
            if not any(
                item.enabled and item.mode is TransmissionMode.CYCLIC
                for item in self.messages
            ):
                raise ConflictError("Transmission plan has no cyclic messages")
            self.state = TransmissionPlanState.PAUSED
            for message in self.messages:
                if message.enabled and message.mode is TransmissionMode.CYCLIC:
                    self._telemetry[message.message_id].state = "paused"
        self._wake.set()
        return self.snapshot()

    async def resume(self) -> dict[str, object]:
        async with self._send_lock:
            if self.state is not TransmissionPlanState.PAUSED:
                raise ConflictError("Only a paused transmission can be resumed")
            self.state = TransmissionPlanState.RUNNING
            for message in self.messages:
                if message.enabled and message.mode is TransmissionMode.CYCLIC:
                    self._telemetry[message.message_id].state = "active"
        self._wake.set()
        return self.snapshot()

    async def stop(self) -> dict[str, object]:
        async with self._send_lock:
            if self.state not in {
                TransmissionPlanState.RUNNING,
                TransmissionPlanState.PAUSED,
            }:
                raise ConflictError("Transmission plan is not active")
            self.state = TransmissionPlanState.STOPPED
            for telemetry in self._telemetry.values():
                telemetry.state = "stopped"
        self._wake.set()
        task = self._task
        if task is not None and task is not asyncio.current_task():
            await task
        self._task = None
        return self.snapshot()

    async def stop_if_active(self) -> None:
        if self.state in {
            TransmissionPlanState.RUNNING,
            TransmissionPlanState.PAUSED,
        }:
            await self.stop()

    async def send_once(self) -> dict[str, object]:
        if self.state is not TransmissionPlanState.STOPPED or self._task is not None:
            raise ConflictError("Stop the cyclic transmission before sending once")
        for message in self.messages:
            if message.enabled:
                await self._send(message, allow_stopped=True)
                telemetry = self._telemetry[message.message_id]
                if telemetry.last_error is None:
                    telemetry.state = "stopped"
        return self.snapshot()

    async def _run(self) -> None:
        cyclic = [
            message
            for message in self.messages
            if message.enabled and message.mode is TransmissionMode.CYCLIC
        ]
        singles = [
            message
            for message in self.messages
            if message.enabled and message.mode is TransmissionMode.SINGLE
        ]
        for message in singles:
            # Pausar afeta somente mensagens cíclicas; envios únicos que fazem
            # parte do start continuam válidos, salvo se o plano for parado.
            await self._send(message, allow_paused=True)
            telemetry = self._telemetry[message.message_id]
            if telemetry.last_error is None:
                telemetry.state = "stopped"
        if self.state is TransmissionPlanState.STOPPED:
            self._task = None
            return
        if not cyclic:
            self.state = TransmissionPlanState.STOPPED
            self._task = None
            return

        now = self._monotonic()
        schedule: list[tuple[float, int, TransmissionMessage]] = []
        for index, message in enumerate(cyclic):
            self._telemetry[message.message_id].state = (
                "paused"
                if self.state is TransmissionPlanState.PAUSED
                else "active"
            )
            heapq.heappush(schedule, (now, index, message))

        while self.state in {
            TransmissionPlanState.RUNNING,
            TransmissionPlanState.PAUSED,
        }:
            if self.state is TransmissionPlanState.PAUSED:
                self._wake.clear()
                await self._wake.wait()
                if self.state is TransmissionPlanState.RUNNING:
                    resumed = self._monotonic()
                    schedule = [
                        (resumed, index, message)
                        for _, index, message in schedule
                    ]
                    heapq.heapify(schedule)
                continue

            deadline, index, message = schedule[0]
            delay = max(0.0, deadline - self._monotonic())
            self._wake.clear()
            try:
                await asyncio.wait_for(self._wake.wait(), timeout=delay)
                continue
            except TimeoutError:
                pass

            heapq.heappop(schedule)
            await self._send(message)
            assert message.period_ms is not None
            next_deadline, misses = self.next_deadline(
                deadline, message.period_ms / 1000.0, self._monotonic()
            )
            self._telemetry[message.message_id].deadline_misses += misses
            heapq.heappush(schedule, (next_deadline, index, message))

    async def _send(
        self,
        message: TransmissionMessage,
        *,
        allow_stopped: bool = False,
        allow_paused: bool = False,
    ) -> None:
        telemetry = self._telemetry[message.message_id]
        async with self._send_lock:
            allowed_state = self.state is TransmissionPlanState.RUNNING or (
                allow_paused and self.state is TransmissionPlanState.PAUSED
            )
            if not allow_stopped and not allowed_state:
                return
            try:
                command, crc_value = message.command()
                await self._sender(command)
                telemetry.sent_frames += 1
                telemetry.last_transmission = datetime.now(timezone.utc)
                telemetry.last_error = None
                telemetry.last_crc = crc_value
                telemetry.state = (
                    "active"
                    if message.mode is TransmissionMode.CYCLIC
                    else "stopped"
                )
            except Exception as error:
                telemetry.send_errors += 1
                telemetry.last_error = str(error)
                telemetry.state = "error"

    @staticmethod
    def next_deadline(deadline: float, period: float, now: float) -> tuple[float, int]:
        candidate = deadline + period
        if candidate > now:
            return candidate, 0
        missed = math.floor((now - candidate) / period) + 1
        return candidate + missed * period, missed

    def snapshot(self) -> dict[str, object]:
        return {
            "plan_id": self.plan_id,
            "session_id": self.session_id,
            "interface": self.interface,
            "state": self.state.value,
            "messages": [
                self._message_snapshot(message) for message in self.messages
            ],
            "sent_frames": sum(item.sent_frames for item in self._telemetry.values()),
            "send_errors": sum(item.send_errors for item in self._telemetry.values()),
            "deadline_misses": sum(
                item.deadline_misses for item in self._telemetry.values()
            ),
            "estimated_bus_load_percent": self._estimated_bus_load(),
        }

    def _estimated_bus_load(self) -> float | None:
        if not self._bitrate or any(message.is_fd for message in self.messages):
            return None
        bits_per_second = sum(
            (47 + len(message.payload) * 8) * 1.2 * (message.frequency_hz or 0)
            for message in self.messages
            if message.enabled and message.mode is TransmissionMode.CYCLIC
        )
        return bits_per_second / self._bitrate * 100

    def _message_snapshot(self, message: TransmissionMessage) -> dict[str, object]:
        telemetry = self._telemetry[message.message_id]
        return {
            "message_id": message.message_id,
            "enabled": message.enabled,
            "can_id": message.can_id,
            "is_extended_id": message.is_extended_id,
            "is_fd": message.is_fd,
            "mode": message.mode.value,
            "period_ms": message.period_ms,
            "frequency_hz": message.frequency_hz,
            "crc_enabled": message.crc is not None,
            "state": telemetry.state,
            "sent_frames": telemetry.sent_frames,
            "send_errors": telemetry.send_errors,
            "deadline_misses": telemetry.deadline_misses,
            "last_transmission": telemetry.last_transmission.isoformat()
            if telemetry.last_transmission
            else None,
            "last_error": telemetry.last_error,
            "last_crc": telemetry.last_crc,
        }
