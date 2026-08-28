"""Bounded python-can adapter for Linux SocketCAN."""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from typing import Protocol

import can

from can_monitor.domain.models import (
    CanFrame,
    Direction,
    FilterConfig,
    SendFrameCommand,
)
from can_monitor.errors import CanAdapterError

logger = logging.getLogger(__name__)


class CanBusAdapter(Protocol):
    dropped_frames: int

    async def open(self, interface: str, fd: bool, filters: FilterConfig) -> None: ...

    async def close(self) -> None: ...

    async def frames(self) -> AsyncIterator[CanFrame]: ...

    async def set_filters(self, filters: FilterConfig) -> None: ...

    async def send(self, command: SendFrameCommand) -> None: ...


class _QueueListener(can.Listener):
    def __init__(self, queue: asyncio.Queue[CanFrame], interface: str) -> None:
        self.queue = queue
        self.interface = interface
        self.dropped_frames = 0

    def on_message_received(self, message: can.Message) -> None:
        frame = CanFrame(
            capture_timestamp_ns=round(message.timestamp * 1_000_000_000),
            ingress_monotonic_ns=time.monotonic_ns(),
            interface=str(message.channel or self.interface),
            can_id=message.arbitration_id,
            is_extended_id=message.is_extended_id,
            is_fd=message.is_fd,
            dlc=message.dlc,
            data=bytes(message.data),
            direction=Direction.RX if message.is_rx else Direction.TX,
            is_error_frame=message.is_error_frame,
            is_remote_frame=message.is_remote_frame,
            bitrate_switch=message.bitrate_switch if message.is_fd else None,
            error_state_indicator=(
                message.error_state_indicator if message.is_fd else None
            ),
        )
        if self.queue.full():
            try:
                self.queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
            self.dropped_frames += 1
        self.queue.put_nowait(frame)


class PythonCanSocketCanAdapter:
    def __init__(self, queue_size: int = 8192) -> None:
        self._queue: asyncio.Queue[CanFrame] = asyncio.Queue(maxsize=queue_size)
        self._bus: can.BusABC | None = None
        self._notifier: can.Notifier | None = None
        self._listener: _QueueListener | None = None
        self._closed = asyncio.Event()

    @property
    def dropped_frames(self) -> int:
        return self._listener.dropped_frames if self._listener else 0

    async def open(self, interface: str, fd: bool, filters: FilterConfig) -> None:
        if self._bus is not None:
            raise CanAdapterError("CAN adapter is already open")
        bus: can.BusABC | None = None
        try:
            bus = await asyncio.to_thread(
                can.Bus,
                interface="socketcan",
                channel=interface,
                fd=fd,
                receive_own_messages=True,
                can_filters=filters.as_python_can(),
            )
            listener = _QueueListener(self._queue, interface)
            notifier = can.Notifier(
                bus,
                [listener],
                loop=asyncio.get_running_loop(),
            )
        except (can.CanError, OSError, RuntimeError, ValueError) as error:
            if bus is not None:
                await asyncio.to_thread(bus.shutdown)
            raise CanAdapterError(
                f"Could not open SocketCAN interface {interface}: {error}"
            ) from error
        self._bus = bus
        self._listener = listener
        self._notifier = notifier
        self._closed.clear()

    async def close(self) -> None:
        notifier, bus = self._notifier, self._bus
        self._notifier = None
        self._bus = None
        self._closed.set()
        cleanup_errors: list[str] = []
        try:
            if notifier is not None:
                await asyncio.to_thread(notifier.stop, 2.0)
        except Exception as error:
            cleanup_errors.append(f"notifier: {error}")
        finally:
            try:
                if bus is not None:
                    await asyncio.to_thread(bus.shutdown)
            except Exception as error:
                cleanup_errors.append(f"bus: {error}")
        if cleanup_errors:
            raise CanAdapterError("; ".join(cleanup_errors))

    async def frames(self) -> AsyncIterator[CanFrame]:
        while not self._closed.is_set() or not self._queue.empty():
            try:
                yield await asyncio.wait_for(self._queue.get(), timeout=0.25)
            except TimeoutError:
                continue

    async def set_filters(self, filters: FilterConfig) -> None:
        if self._bus is None:
            raise CanAdapterError("CAN adapter is not open")
        try:
            await asyncio.to_thread(self._bus.set_filters, filters.as_python_can())
        except (can.CanError, OSError) as error:
            raise CanAdapterError(f"Could not update CAN filters: {error}") from error

    async def send(self, command: SendFrameCommand) -> None:
        if self._bus is None:
            raise CanAdapterError("CAN adapter is not open")
        message = can.Message(
            arbitration_id=command.can_id,
            is_extended_id=command.is_extended_id,
            is_fd=command.is_fd,
            data=command.data,
            check=True,
        )
        try:
            await asyncio.to_thread(self._bus.send, message, 1.0)
        except (can.CanError, OSError, ValueError) as error:
            raise CanAdapterError(f"Could not transmit CAN frame: {error}") from error
