import pytest

from can_monitor.domain.crc import (
    CRC_PRESETS,
    ByteOrder,
    CrcInsertion,
    CrcParameters,
    calculate_crc,
    insert_crc,
)


@pytest.mark.parametrize(
    ("name", "check"),
    [
        ("CRC-8/SAE-J1850", 0x4B),
        ("CRC-8/AUTOSAR", 0xDF),
        ("CRC-8/HITAG", 0xB4),
        ("CRC-8/MAXIM-DOW", 0xA1),
        ("CRC-16/CCITT-FALSE", 0x29B1),
        ("CRC-16/ARC", 0xBB3D),
        ("CRC-32/ISO-HDLC", 0xCBF43926),
    ],
)
def test_crc_presets_match_standard_check_vectors(name: str, check: int) -> None:
    assert calculate_crc(b"123456789", CRC_PRESETS[name]) == check


def test_custom_parameters_reflection_initial_value_and_xorout() -> None:
    reflected = CrcParameters("CUSTOM", 8, 0x31, 0x00, 0x00, True, True)
    with_init_and_xor = CrcParameters(
        "CUSTOM", 8, 0x1D, 0xFF, 0xFF, False, False
    )
    assert calculate_crc(b"123456789", reflected) == 0xA1
    assert calculate_crc(b"123456789", with_init_and_xor) == 0x4B


def test_partial_range_and_crc8_insertion() -> None:
    payload, value = insert_crc(
        b"123456789\x00",
        CrcInsertion(CRC_PRESETS["CRC-8/SAE-J1850"], 0, 8, 9),
    )
    assert value == 0x4B
    assert payload == b"123456789\x4b"


@pytest.mark.parametrize(
    ("order", "expected"),
    [
        (ByteOrder.BIG, "31323334353637383929B1"),
        (ByteOrder.LITTLE, "313233343536373839B129"),
    ],
)
def test_crc16_endianness(order: ByteOrder, expected: str) -> None:
    payload, value = insert_crc(
        b"123456789\x00\x00",
        CrcInsertion(CRC_PRESETS["CRC-16/CCITT-FALSE"], 0, 8, 9, order),
    )
    assert value == 0x29B1
    assert payload == bytes.fromhex(expected)


def test_crc32_requires_four_available_bytes() -> None:
    with pytest.raises(ValueError, match="enough space"):
        insert_crc(
            bytes(8),
            CrcInsertion(CRC_PRESETS["CRC-32/ISO-HDLC"], 0, 3, 6),
        )
