"""CAN identifiers and payload validation."""

from __future__ import annotations

import re

from can_monitor.errors import InvalidRequestError

_HEX_PAYLOAD = re.compile(r"^(?:[0-9A-Fa-f]{2})(?:[\s:_-]?[0-9A-Fa-f]{2})*$")
_FD_LENGTHS = frozenset((*range(0, 9), 12, 16, 20, 24, 32, 48, 64))


def validate_can_id(can_id: int, is_extended_id: bool) -> int:
    maximum = 0x1FFFFFFF if is_extended_id else 0x7FF
    if not 0 <= can_id <= maximum:
        width = "29-bit extended" if is_extended_id else "11-bit standard"
        raise InvalidRequestError(f"CAN ID {can_id:#x} is outside the {width} range")
    return can_id


def parse_hex_payload(value: str, *, is_fd: bool) -> bytes:
    compact = re.sub(r"[\s:_-]", "", value.strip())
    if not compact:
        data = b""
    else:
        if not _HEX_PAYLOAD.fullmatch(value.strip()):
            raise InvalidRequestError("Payload must contain complete hexadecimal bytes")
        data = bytes.fromhex(compact)

    if is_fd:
        if len(data) not in _FD_LENGTHS:
            raise InvalidRequestError(
                "CAN FD payload length must be 0..8, 12, 16, 20, 24, 32, 48 or 64 bytes"
            )
    elif len(data) > 8:
        raise InvalidRequestError("Classical CAN payload cannot exceed 8 bytes")
    return data
