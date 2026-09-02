import asyncio

from can_monitor.application.session import CanSession
from can_monitor.domain.models import (
    CanFrame,
    CanIdFilter,
    CanInterfaceInfo,
    Direction,
    FilterConfig,
    FilterMode,
    SessionState,
)
from tests.fakes import FakeAdapter


def _frame(sequence: int) -> CanFrame:
    return CanFrame(
        capture_timestamp_ns=1_000_000 - sequence,
        ingress_monotonic_ns=sequence,
        interface="vcan0",
        can_id=0x123,
        is_extended_id=False,
        is_fd=False,
        dlc=1,
        data=b"\x01",
        direction=Direction.RX,
    )


def _session(adapter: FakeAdapter) -> CanSession:
    return CanSession(
        "test-session",
        CanInterfaceInfo("vcan0", "vcan"),
        False,
        FilterConfig(FilterMode.ALL),
        adapter,
        trace_buffer_size=8,
        client_queue_size=8,
        tx_enabled=False,
        virtual_tx_enabled=True,
        tx_rate_limit_per_second=10,
    )


class AcquisitionFailureAdapter(FakeAdapter):
    def __init__(self, *, close_fails: bool = False) -> None:
        super().__init__()
        self.close_fails = close_fails

    async def frames(self):
        await asyncio.sleep(0)
        raise RuntimeError("acquisition exploded")
        yield  # pragma: no cover - keeps this an async generator

    async def close(self) -> None:
        await super().close()
        if self.close_fails:
            raise RuntimeError("close exploded")


class BlockingFilterAdapter(FakeAdapter):
    def __init__(self) -> None:
        super().__init__()
        self.filter_started = asyncio.Event()
        self.filter_release = asyncio.Event()

    async def set_filters(self, filters: FilterConfig) -> None:
        self.filter_started.set()
        await self.filter_release.wait()
        await super().set_filters(filters)


def test_acquisition_failure_closes_adapter_and_wakes_subscriber() -> None:
    async def scenario() -> None:
        adapter = AcquisitionFailureAdapter(close_fails=True)
        session = _session(adapter)
        await session.connect()
        subscription = session.subscribe()
        assert await asyncio.wait_for(subscription.queue.get(), timeout=1) is None
        assert session.state is SessionState.ERROR
        assert adapter.close_calls >= 1
        assert session.error is not None
        assert "acquisition exploded" in session.error
        assert "close exploded" in session.error
        await session.close()

    asyncio.run(scenario())


def test_explicit_close_always_sends_terminal_sentinel() -> None:
    async def scenario() -> None:
        adapter = FakeAdapter()
        session = _session(adapter)
        await session.connect()
        subscription = session.subscribe()
        await session.close()
        assert await asyncio.wait_for(subscription.queue.get(), timeout=1) is None
        assert session.state is SessionState.DISCONNECTED
        assert adapter.close_calls >= 1

    asyncio.run(scenario())


def test_filter_revision_has_a_consistent_application_boundary() -> None:
    async def scenario() -> None:
        adapter = BlockingFilterAdapter()
        session = _session(adapter)
        await session.connect()
        subscription = session.subscribe()

        await adapter.queue.put(_frame(1))
        before = await asyncio.wait_for(subscription.queue.get(), timeout=1)
        assert before is not None and before.filter_revision == 1

        update = asyncio.create_task(
            session.update_filters(
                FilterConfig(
                    FilterMode.FILTERED,
                    (CanIdFilter(0x123, False),),
                )
            )
        )
        await adapter.filter_started.wait()
        await adapter.queue.put(_frame(2))
        adapter.filter_release.set()
        await update
        during = await asyncio.wait_for(subscription.queue.get(), timeout=1)
        assert during is not None and during.filter_revision == 2
        await session.close()

    asyncio.run(scenario())
