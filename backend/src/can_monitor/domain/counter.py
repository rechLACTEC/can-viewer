"""Bit-level automatic counter support for transmitted CAN payloads."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class CounterConfig:
    """Counter field where bit 0 is the LSB of payload byte 0."""

    bit_offset: int
    bit_length: int
    initial_value: int = 0
    increment: int = 1

    @property
    def modulus(self) -> int:
        return 1 << self.bit_length

    @property
    def maximum_value(self) -> int:
        return self.modulus - 1

    def validate(self, payload_length: int) -> None:
        if not 1 <= self.bit_length <= 8:
            raise ValueError("Counter bit_length must be between 1 and 8")
        if self.bit_offset < 0:
            raise ValueError("Counter bit_offset must be non-negative")
        if self.bit_offset + self.bit_length > payload_length * 8:
            raise ValueError("Counter field is outside the payload")
        if not 0 <= self.initial_value <= self.maximum_value:
            raise ValueError("Counter initial_value does not fit in bit_length")
        if self.increment <= 0:
            raise ValueError("Counter increment must be positive")

    def next_value(self, current_value: int) -> int:
        return (current_value + self.increment) % self.modulus


def insert_bit_field(
    payload: bytes, *, bit_offset: int, bit_length: int, value: int
) -> bytes:
    """Return payload with one unsigned field replaced, preserving all other bits."""

    config = CounterConfig(bit_offset, bit_length, value, 1)
    config.validate(len(payload))
    result = bytearray(payload)
    for field_bit in range(bit_length):
        absolute_bit = bit_offset + field_bit
        byte_index, bit_in_byte = divmod(absolute_bit, 8)
        mask = 1 << bit_in_byte
        if value & (1 << field_bit):
            result[byte_index] |= mask
        else:
            result[byte_index] &= ~mask
    return bytes(result)
