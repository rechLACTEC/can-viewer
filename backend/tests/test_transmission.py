from __future__ import annotations

import asyncio
import time

import pytest
from fastapi.testclient import TestClient

from can_monitor.api.app import create_app
from can_monitor.api.schemas import TransmissionMessageRequest
from can_monitor.application.transmission import (
    TransmissionMessage,
    TransmissionMode,
    TransmissionPlan,
)
from can_monitor.config import Settings
from can_monitor.domain.crc import CRC_PRESETS, CrcInsertion
from can_monitor.domain.models import CanInterfaceInfo, SendFrameCommand
from can_monitor.errors import ConflictError
from tests.fakes import FakeAdapter, FakeDiscoverer


def _message(
    message_id: str,
    *,
    mode: TransmissionMode = TransmissionMode.CYCLIC,
    period_ms: float | None = 20,
    enabled: bool = True,
    payload: bytes = b"\x01",
    crc: CrcInsertion | None = None,
) -> TransmissionMessage:
    return TransmissionMessage(
        message_id=message_id,
        enabled=enabled,
        can_id=0x123,
        is_extended_id=False,
        is_fd=False,
        payload=payload,
        mode=mode,
        period_ms=period_ms if mode is TransmissionMode.CYCLIC else None,
        crc=crc,
    )


def test_multiple_messages_use_independent_periods_and_disabled_is_skipped() -> None:
    async def scenario() -> None:
        sent: list[SendFrameCommand] = []

        async def sender(command: SendFrameCommand) -> None:
            sent.append(command)

        plan = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(
                _message("fast", period_ms=20, payload=b"\x01"),
                _message("slow", period_ms=50, payload=b"\x02"),
                _message("disabled", period_ms=10, enabled=False, payload=b"\x03"),
            ),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.13)
        await plan.stop()

        fast = sum(command.data == b"\x01" for command in sent)
        slow = sum(command.data == b"\x02" for command in sent)
        assert 5 <= fast <= 8
        assert 2 <= slow <= 4
        assert all(command.data != b"\x03" for command in sent)
        assert fast > slow

    asyncio.run(scenario())


def test_single_messages_send_once_on_start_and_send_once_operation() -> None:
    async def scenario() -> None:
        sent: list[bytes] = []

        async def sender(command: SendFrameCommand) -> None:
            sent.append(command.data)

        plan = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(
                _message("one", mode=TransmissionMode.SINGLE, payload=b"\x01"),
                _message(
                    "disabled",
                    mode=TransmissionMode.SINGLE,
                    enabled=False,
                    payload=b"\x02",
                ),
            ),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.01)
        assert sent == [b"\x01"]

        second = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(
                _message("a", period_ms=10, payload=b"\x03"),
                _message("b", mode=TransmissionMode.SINGLE, payload=b"\x04"),
            ),
            sender=sender,
        )
        status = await second.send_once()
        assert sent[-2:] == [b"\x03", b"\x04"]
        assert all(item["state"] == "stopped" for item in status["messages"])

    asyncio.run(scenario())


def test_pause_resume_multiple_cycles_and_stop() -> None:
    async def scenario() -> None:
        sent = 0

        async def sender(_: SendFrameCommand) -> None:
            nonlocal sent
            sent += 1

        plan = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(_message("cyclic", period_ms=10),),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.035)
        await plan.pause()
        paused_at = sent
        await asyncio.sleep(0.03)
        assert sent == paused_at
        await plan.resume()
        await asyncio.sleep(0.025)
        await plan.pause()
        assert sent > paused_at
        second_pause = sent
        await asyncio.sleep(0.02)
        assert sent == second_pause
        await plan.resume()
        await asyncio.sleep(0.015)
        status = await plan.stop()
        stopped_at = sent
        await asyncio.sleep(0.02)
        assert sent == stopped_at
        assert status["state"] == "stopped"

    asyncio.run(scenario())


def test_immediate_pause_does_not_cancel_single_messages_from_start() -> None:
    async def scenario() -> None:
        sent: list[bytes] = []

        async def sender(command: SendFrameCommand) -> None:
            sent.append(command.data)

        plan = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(
                _message("single", mode=TransmissionMode.SINGLE, payload=b"\x01"),
                _message("cyclic", period_ms=20, payload=b"\x02"),
            ),
            sender=sender,
        )
        plan.start()
        await plan.pause()
        await asyncio.sleep(0.01)
        assert sent == [b"\x01"]
        await plan.stop()

    asyncio.run(scenario())


def test_errors_and_crc_are_reported_per_message() -> None:
    async def scenario() -> None:
        attempts = 0

        async def sender(command: SendFrameCommand) -> None:
            nonlocal attempts
            attempts += 1
            assert command.data[-1] == 0x4B
            if attempts == 1:
                raise OSError("send failed")

        crc = CrcInsertion(CRC_PRESETS["CRC-8/SAE-J1850"], 0, 8, 9)
        plan = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(_message("crc", period_ms=10, payload=b"123456789\x00", crc=crc),),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.025)
        await plan.stop()
        message = plan.snapshot()["messages"][0]
        assert message["send_errors"] == 1
        assert message["sent_frames"] >= 1
        assert message["last_crc"] == 0x4B

    asyncio.run(scenario())


def test_absolute_deadlines_do_not_accumulate_drift_and_skip_missed_periods() -> None:
    deadline = 10.0
    for now in (10.001, 10.101, 10.201):
        deadline, misses = TransmissionPlan.next_deadline(deadline, 0.1, now)
        assert misses == 0
    assert deadline == pytest.approx(10.3)

    deadline, misses = TransmissionPlan.next_deadline(10.0, 0.1, 10.46)
    assert deadline == pytest.approx(10.5)
    assert misses == 4


@pytest.mark.parametrize("frequency_hz", [1, 10, 20, 50, 100, 200])
def test_supported_frequencies_convert_to_the_expected_period(
    frequency_hz: int,
) -> None:
    request = TransmissionMessageRequest(
        message_id=f"frequency-{frequency_hz}",
        can_id=0x123,
        data_hex="01",
        mode="cyclic",
        period_ms=1000 / frequency_hz,
    )
    message = request.to_domain()
    assert message.period_ms == pytest.approx(1000 / frequency_hz)
    assert message.frequency_hz == pytest.approx(frequency_hz)


def test_frequency_above_200_hz_is_rejected() -> None:
    with pytest.raises(ValueError, match="greater than or equal to 5"):
        TransmissionMessageRequest(
            message_id="too-fast",
            can_id=0x123,
            data_hex="01",
            mode="cyclic",
            period_ms=4.99,
        )


def test_200_hz_scheduler_has_bounded_drift_and_reports_effective_frequency() -> None:
    async def scenario() -> None:
        sent_at: list[float] = []

        async def sender(_: SendFrameCommand) -> None:
            sent_at.append(time.monotonic())

        plan = TransmissionPlan(
            session_id="session-200hz",
            interface="vcan0",
            messages=(_message("fast", period_ms=5),),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.16)
        await plan.stop()

        assert 20 <= len(sent_at) <= 45
        elapsed = sent_at[-1] - sent_at[0]
        effective = (len(sent_at) - 1) / elapsed
        assert effective == pytest.approx(200, rel=0.35)
        telemetry = plan.snapshot()["messages"][0]
        assert telemetry["configured_frequency_hz"] == pytest.approx(200)
        assert telemetry["effective_frequency_hz"] == pytest.approx(
            effective, rel=0.01
        )

    asyncio.run(scenario())


def test_invalid_controls_are_rejected() -> None:
    async def scenario() -> None:
        async def sender(_: SendFrameCommand) -> None:
            pass

        plan = TransmissionPlan(
            session_id="session-1",
            interface="vcan0",
            messages=(_message("a"),),
            sender=sender,
        )
        with pytest.raises(ConflictError):
            await plan.pause()
        plan.start()
        with pytest.raises(ConflictError):
            plan.start()
        await plan.stop()
        with pytest.raises(ConflictError):
            await plan.resume()

    asyncio.run(scenario())


def _request_messages() -> list[dict[str, object]]:
    return [
        {
            "message_id": "first",
            "enabled": True,
            "can_id": 0x123,
            "is_extended_id": False,
            "is_fd": False,
            "data_hex": "3132333435363700",
            "mode": "cyclic",
            "period_ms": 20,
            "crc": {
                "algorithm": "CRC-8/SAE-J1850",
                "range_start": 0,
                "range_end": 6,
                "position": 7,
            },
        },
        {
            "message_id": "second",
            "enabled": True,
            "can_id": 0x1ABCDE,
            "is_extended_id": True,
            "is_fd": False,
            "data_hex": "0102",
            "mode": "single",
        },
    ]


def test_transmission_api_configuration_preview_lifecycle_and_stop_all() -> None:
    adapters: list[FakeAdapter] = []

    def factory() -> FakeAdapter:
        adapter = FakeAdapter()
        adapters.append(adapter)
        return adapter

    app = create_app(
        Settings(cors_origins=(), tx_rate_limit_per_second=1000),
        adapter_factory=factory,
        discoverer=FakeDiscoverer(
            [CanInterfaceInfo("vcan0", "vcan", bitrate=500_000)]
        ),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
        ).json()
        base = f"/api/v1/can/sessions/{session['id']}/transmissions"
        body = {"messages": _request_messages()}
        preview = client.post(f"{base}/preview", json=body["messages"][0])
        assert preview.status_code == 200
        assert preview.json()["payload_hex"].startswith("31323334353637")
        assert not preview.json()["payload_hex"].endswith("00")

        configured = client.post(base, json=body)
        assert configured.status_code == 201
        plan_id = configured.json()["plan_id"]
        assert configured.json()["estimated_bus_load_percent"] is not None
        started = client.post(f"{base}/{plan_id}/start")
        assert started.json()["state"] == "running"
        paused = client.post(f"{base}/{plan_id}/pause")
        assert paused.json()["state"] == "paused"
        resumed = client.post(f"{base}/{plan_id}/resume")
        assert resumed.json()["state"] == "running"
        status = client.get(f"{base}/{plan_id}")
        assert len(status.json()["messages"]) == 2
        stopped = client.post(f"{base}/stop-all")
        assert stopped.json()["stopped"] == 1

        once = client.post(f"{base}/send-once", json=body)
        assert once.status_code == 202
        assert once.json()["sent_frames"] == 2
        assert len(adapters[0].sent) >= 2


def test_aggregate_limit_is_distinct_from_per_message_200_hz_limit() -> None:
    app = create_app(
        Settings(cors_origins=(), tx_rate_limit_per_second=1000),
        adapter_factory=FakeAdapter,
        discoverer=FakeDiscoverer(
            [CanInterfaceInfo("vcan0", "vcan", bitrate=500_000)]
        ),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
        ).json()
        path = f"/api/v1/can/sessions/{session['id']}/transmissions"
        base_message = _request_messages()[0]
        four_at_200 = [
            {**base_message, "message_id": f"message-{index}", "period_ms": 5}
            for index in range(4)
        ]
        accepted = client.post(path, json={"messages": four_at_200})
        assert accepted.status_code == 201
        assert accepted.json()["estimated_bus_load_percent"] is not None

        six_at_200 = [
            {**base_message, "message_id": f"overload-{index}", "period_ms": 5}
            for index in range(6)
        ]
        rejected = client.post(path, json={"messages": six_at_200})
        assert rejected.status_code == 400
        assert "Aggregate cyclic frequency" in rejected.json()["detail"]


def test_shutdown_stops_cyclic_scheduler() -> None:
    adapters: list[FakeAdapter] = []

    def factory() -> FakeAdapter:
        adapter = FakeAdapter()
        adapters.append(adapter)
        return adapter

    app = create_app(
        Settings(cors_origins=(), tx_rate_limit_per_second=1000),
        adapter_factory=factory,
        discoverer=FakeDiscoverer([CanInterfaceInfo("vcan0", "vcan")]),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
        ).json()
        base = f"/api/v1/can/sessions/{session['id']}/transmissions"
        configured = client.post(
            base,
            json={"messages": [_request_messages()[0]]},
        ).json()
        client.post(f"{base}/{configured['plan_id']}/start")
    count = len(adapters[0].sent)
    assert adapters[0].closed
    assert len(adapters[0].sent) == count


def test_disabling_physical_tx_stops_active_cyclic_plan() -> None:
    adapter = FakeAdapter()
    app = create_app(
        Settings(
            cors_origins=(),
            tx_enabled=True,
            tx_rate_limit_per_second=100,
        ),
        adapter_factory=lambda: adapter,
        discoverer=FakeDiscoverer([CanInterfaceInfo("can0", "physical")]),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "can0", "filter": {"mode": "all", "ids": []}},
        ).json()
        base = f"/api/v1/can/sessions/{session['id']}/transmissions"
        configured = client.post(
            base,
            json={"messages": [_request_messages()[0]]},
        ).json()
        plan_id = configured["plan_id"]
        assert client.post(f"{base}/{plan_id}/start").json()["state"] == "running"
        time.sleep(0.03)
        assert adapter.sent

        disabled = client.put("/api/v1/can/tx-enabled", json={"enabled": False})
        assert disabled.json() == {"enabled": False}
        assert client.get(f"{base}/{plan_id}").json()["state"] == "stopped"
        sent_when_disabled = len(adapter.sent)
        time.sleep(0.03)
        assert len(adapter.sent) == sent_when_disabled
        assert client.get(f"/api/v1/can/sessions/{session['id']}").json()[
            "state"
        ] == "connected"


def test_physical_cyclic_plan_cannot_start_until_runtime_tx_is_enabled() -> None:
    adapter = FakeAdapter()
    app = create_app(
        Settings(cors_origins=(), tx_rate_limit_per_second=100),
        adapter_factory=lambda: adapter,
        discoverer=FakeDiscoverer([CanInterfaceInfo("can0", "physical")]),
    )
    with TestClient(app) as client:
        session = client.post(
            "/api/v1/can/sessions",
            json={"interface": "can0", "filter": {"mode": "all", "ids": []}},
        ).json()
        base = f"/api/v1/can/sessions/{session['id']}/transmissions"
        configured = client.post(
            base,
            json={"messages": [_request_messages()[0]]},
        ).json()
        start_path = f"{base}/{configured['plan_id']}/start"

        blocked = client.post(start_path)
        assert blocked.status_code == 403
        assert blocked.json()["code"] == "transmission_disabled"
        assert adapter.sent == []

        assert client.put(
            "/api/v1/can/tx-enabled", json={"enabled": True}
        ).json() == {"enabled": True}
        assert client.post(start_path).json()["state"] == "running"
        time.sleep(0.03)
        assert adapter.sent
