from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator

from can_monitor.domain.models import CanFrame, FilterConfig, SendFrameCommand


class FakeAdapter:
    def __init__(self) -> None:
        self.queue: asyncio.Queue[CanFrame] = asyncio.Queue()
        self.opened: tuple[str, bool, FilterConfig] | None = None
        self.filters: list[FilterConfig] = []
        self.sent: list[SendFrameCommand] = []
        self.closed = False
        self.close_calls = 0
        self.dropped_frames = 0
        self.loop: asyncio.AbstractEventLoop | None = None

    async def open(self, interface: str, fd: bool, filters: FilterConfig) -> None:
        self.opened = (interface, fd, filters)
        self.loop = asyncio.get_running_loop()

    async def close(self) -> None:
        self.close_calls += 1
        self.closed = True

    async def frames(self) -> AsyncIterator[CanFrame]:
        while not self.closed or not self.queue.empty():
            try:
                yield await asyncio.wait_for(self.queue.get(), timeout=0.02)
            except TimeoutError:
                continue

    async def set_filters(self, filters: FilterConfig) -> None:
        self.filters.append(filters)

    async def send(self, command: SendFrameCommand) -> None:
        self.sent.append(command)

    def emit(self, frame: CanFrame) -> None:
        assert self.loop is not None
        future = asyncio.run_coroutine_threadsafe(self.queue.put(frame), self.loop)
        future.result(timeout=1)


class FakeDiscoverer:
    def __init__(self, interfaces):
        self.interfaces = interfaces

    async def discover(self):
        return self.interfaces
