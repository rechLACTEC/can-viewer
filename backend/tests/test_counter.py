from __future__ import annotations

import asyncio

import pytest

from can_monitor.api.schemas import TransmissionMessageRequest
from can_monitor.application.transmission import (
    TransmissionMessage,
    TransmissionMode,
    TransmissionPlan,
)
from can_monitor.domain.counter import CounterConfig, insert_bit_field
from can_monitor.domain.crc import CRC_PRESETS, CrcInsertion, calculate_crc
from can_monitor.domain.models import SendFrameCommand


@pytest.mark.parametrize(
    ("payload", "offset", "length", "value", "expected"),
    [
        (b"\xA0", 0, 4, 5, b"\xA5"),
        (b"\x05", 4, 4, 0xA, b"\xA5"),
        (b"\xA0\x55", 8, 4, 3, b"\xA0\x53"),
        (b"\xA0\x05", 12, 4, 0xB, b"\xA0\xB5"),
        (b"\x87", 3, 4, 5, b"\xAF"),
        (b"\x3F\xFC", 6, 4, 9, b"\x7F\xFE"),
    ],
)
def test_insert_bit_field_preserves_unrelated_bits(
    payload: bytes, offset: int, length: int, value: int, expected: bytes
) -> None:
    assert insert_bit_field(
        payload, bit_offset=offset, bit_length=length, value=value
    ) == expected


@pytest.mark.parametrize(("bits", "maximum"), [(1, 1), (4, 15), (8, 255)])
def test_counter_wraps_for_supported_widths(bits: int, maximum: int) -> None:
    counter = CounterConfig(0, bits)
    value = 0
    observed = []
    for _ in range(maximum + 2):
        observed.append(value)
        value = counter.next_value(value)
    assert observed[0] == 0
    assert observed[maximum] == maximum
    assert observed[maximum + 1] == 0


def test_initial_value_and_non_default_increment_wrap() -> None:
    counter = CounterConfig(0, 4, initial_value=13, increment=3)
    assert counter.next_value(13) == 0
    assert counter.next_value(0) == 3


@pytest.mark.parametrize(
    "counter,match",
    [
        (CounterConfig(62, 4), "outside"),
        (CounterConfig(0, 4, initial_value=16), "does not fit"),
    ],
)
def test_invalid_counter_configuration_is_rejected(
    counter: CounterConfig, match: str
) -> None:
    with pytest.raises(ValueError, match=match):
        counter.validate(8)


def _message(
    message_id: str,
    counter: CounterConfig,
    *,
    payload: bytes = b"\xA0\x00",
    crc: CrcInsertion | None = None,
) -> TransmissionMessage:
    return TransmissionMessage(
        message_id=message_id,
        enabled=True,
        can_id=0x123,
        is_extended_id=False,
        is_fd=False,
        payload=payload,
        mode=TransmissionMode.CYCLIC,
        period_ms=5,
        crc=crc,
        counter=counter,
    )


def test_failed_send_does_not_consume_counter() -> None:
    async def scenario() -> None:
        attempts = 0
        sent: list[bytes] = []

        async def sender(command: SendFrameCommand) -> None:
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise OSError("failed")
            sent.append(command.data)

        plan = TransmissionPlan(
            session_id="session",
            interface="vcan0",
            messages=(_message("first", CounterConfig(0, 4, 2, 1)),),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.012)
        await plan.stop()
        assert attempts >= 2
        assert sent[0] == b"\xA2\x00"
        if len(sent) > 1:
            assert sent[1] == b"\xA3\x00"

    asyncio.run(scenario())


def test_multiple_messages_have_independent_counters() -> None:
    async def scenario() -> None:
        sent: list[bytes] = []

        async def sender(command: SendFrameCommand) -> None:
            sent.append(command.data)

        plan = TransmissionPlan(
            session_id="session",
            interface="vcan0",
            messages=(
                _message("first", CounterConfig(0, 4, 2, 1)),
                _message("second", CounterConfig(4, 4, 12, 2)),
            ),
            sender=sender,
        )
        await plan.send_once()
        assert sent == [b"\xA2\x00", b"\xC0\x00"]

    asyncio.run(scenario())


def test_pause_resume_preserves_counter_and_restart_resets_it() -> None:
    async def scenario() -> None:
        sent: list[int] = []

        async def sender(command: SendFrameCommand) -> None:
            sent.append(command.data[0] & 0x0F)

        plan = TransmissionPlan(
            session_id="session",
            interface="vcan0",
            messages=(_message("counter", CounterConfig(0, 4, 5, 1)),),
            sender=sender,
        )
        plan.start()
        await asyncio.sleep(0.012)
        await plan.pause()
        paused_count = len(sent)
        await asyncio.sleep(0.012)
        assert len(sent) == paused_count
        await plan.resume()
        await asyncio.sleep(0.007)
        await plan.stop()
        assert sent == [((5 + index) % 16) for index in range(len(sent))]
        plan.start()
        await asyncio.sleep(0.002)
        await plan.stop()
        assert sent[-1] == 5

    asyncio.run(scenario())


def test_counter_is_inserted_before_crc() -> None:
    crc = CrcInsertion(CRC_PRESETS["CRC-8/SAE-J1850"], 0, 0, 1)
    message = _message(
        "crc", CounterConfig(0, 4, 5, 1), payload=b"\xA0\x00", crc=crc
    )
    after_counter, final_payload, value, crc_value = message.render()
    assert after_counter == b"\xA5\x00"
    assert value == 5
    assert crc_value == calculate_crc(b"\xA5", CRC_PRESETS["CRC-8/SAE-J1850"])
    assert final_payload == bytes((0xA5, crc_value))


def test_counter_crc_write_overlap_is_rejected_by_api_schema() -> None:
    with pytest.raises(ValueError, match="overlaps CRC output"):
        TransmissionMessageRequest.model_validate(
            {
                "message_id": "overlap",
                "can_id": 0x123,
                "data_hex": "0000",
                "mode": "single",
                "counter": {
                    "enabled": True,
                    "bit_offset": 8,
                    "bit_length": 4,
                    "initial_value": 0,
                    "increment": 1,
                },
                "crc": {
                    "algorithm": "CRC-8/SAE-J1850",
                    "range_start": 0,
                    "range_end": 0,
                    "position": 1,
                },
            }
        )
