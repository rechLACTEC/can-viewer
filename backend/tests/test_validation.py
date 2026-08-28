import pytest

from can_monitor.domain.validation import parse_hex_payload, validate_can_id
from can_monitor.errors import InvalidRequestError


def test_standard_and_extended_identifier_boundaries() -> None:
    assert validate_can_id(0x7FF, False) == 0x7FF
    assert validate_can_id(0x1FFFFFFF, True) == 0x1FFFFFFF
    with pytest.raises(InvalidRequestError):
        validate_can_id(0x800, False)
    with pytest.raises(InvalidRequestError):
        validate_can_id(0x20000000, True)


def test_hex_payload_accepts_readable_separators() -> None:
    assert parse_hex_payload("01 0a:FF-20", is_fd=False) == b"\x01\x0a\xff\x20"
    assert parse_hex_payload("", is_fd=False) == b""


@pytest.mark.parametrize("payload", ["0", "GG", "01 2", "0x01"])
def test_hex_payload_rejects_malformed_bytes(payload: str) -> None:
    with pytest.raises(InvalidRequestError):
        parse_hex_payload(payload, is_fd=False)


def test_payload_lengths_are_protocol_aware() -> None:
    with pytest.raises(InvalidRequestError):
        parse_hex_payload("00 " * 9, is_fd=False)
    assert len(parse_hex_payload("00 " * 12, is_fd=True)) == 12
    with pytest.raises(InvalidRequestError):
        parse_hex_payload("00 " * 10, is_fd=True)
