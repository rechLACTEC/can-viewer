"""Generic CRC calculation and payload insertion."""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum


class ByteOrder(StrEnum):
    BIG = "big"
    LITTLE = "little"


@dataclass(frozen=True, slots=True)
class CrcParameters:
    name: str
    width: int
    polynomial: int
    initial_value: int
    xor_out: int
    reflect_input: bool
    reflect_output: bool

    def validate(self) -> None:
        if self.width not in {8, 16, 32}:
            raise ValueError("CRC width must be 8, 16, or 32 bits")
        limit = 1 << self.width
        for name, value in (
            ("polynomial", self.polynomial),
            ("initial_value", self.initial_value),
            ("xor_out", self.xor_out),
        ):
            if not 0 <= value < limit:
                raise ValueError(f"CRC {name} does not fit in {self.width} bits")
        if self.polynomial == 0:
            raise ValueError("CRC polynomial must be greater than zero")


CRC_PRESETS: dict[str, CrcParameters] = {
    item.name: item
    for item in (
        CrcParameters("CRC-8/SAE-J1850", 8, 0x1D, 0xFF, 0xFF, False, False),
        CrcParameters("CRC-8/AUTOSAR", 8, 0x2F, 0xFF, 0xFF, False, False),
        CrcParameters("CRC-8/HITAG", 8, 0x1D, 0xFF, 0x00, False, False),
        CrcParameters("CRC-8/MAXIM-DOW", 8, 0x31, 0x00, 0x00, True, True),
        CrcParameters("CRC-16/CCITT-FALSE", 16, 0x1021, 0xFFFF, 0x0000, False, False),
        CrcParameters("CRC-16/ARC", 16, 0x8005, 0x0000, 0x0000, True, True),
        CrcParameters(
            "CRC-32/ISO-HDLC",
            32,
            0x04C11DB7,
            0xFFFFFFFF,
            0xFFFFFFFF,
            True,
            True,
        ),
    )
}


@dataclass(frozen=True, slots=True)
class CrcInsertion:
    parameters: CrcParameters
    range_start: int
    range_end: int
    position: int
    byte_order: ByteOrder = ByteOrder.BIG


def reflect_bits(value: int, width: int) -> int:
    reflected = 0
    for bit in range(width):
        if value & (1 << bit):
            reflected |= 1 << (width - 1 - bit)
    return reflected


def calculate_crc(data: bytes, parameters: CrcParameters) -> int:
    parameters.validate()
    width = parameters.width
    mask = (1 << width) - 1
    crc = parameters.initial_value
    if parameters.reflect_input:
        polynomial = reflect_bits(parameters.polynomial, width)
        for byte in data:
            crc ^= byte
            for _ in range(8):
                crc = (crc >> 1) ^ polynomial if crc & 1 else crc >> 1
    else:
        top_bit = 1 << (width - 1)
        for byte in data:
            crc ^= byte << (width - 8)
            for _ in range(8):
                crc = ((crc << 1) ^ parameters.polynomial) if crc & top_bit else crc << 1
                crc &= mask
    if parameters.reflect_output != parameters.reflect_input:
        crc = reflect_bits(crc, width)
    return (crc ^ parameters.xor_out) & mask


def insert_crc(payload: bytes, configuration: CrcInsertion) -> tuple[bytes, int]:
    parameters = configuration.parameters
    parameters.validate()
    crc_size = parameters.width // 8
    if not payload:
        raise ValueError("CRC requires a non-empty payload")
    if not 0 <= configuration.range_start <= configuration.range_end < len(payload):
        raise ValueError("CRC calculation range is outside the payload")
    if not 0 <= configuration.position <= len(payload) - crc_size:
        raise ValueError("CRC position does not have enough space in the payload")
    covered = payload[configuration.range_start : configuration.range_end + 1]
    value = calculate_crc(covered, parameters)
    result = bytearray(payload)
    result[configuration.position : configuration.position + crc_size] = value.to_bytes(
        crc_size, configuration.byte_order.value
    )
    return bytes(result), value
