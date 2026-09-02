"""Transport-independent domain models for CAN acquisition."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum


class Direction(StrEnum):
    RX = "rx"
    TX = "tx"


class FilterMode(StrEnum):
    ALL = "all"
    WHITELIST = "whitelist"
    BLACKLIST = "blacklist"


class SessionState(StrEnum):
    CONNECTING = "connecting"
    CONNECTED = "connected"
    DISCONNECTING = "disconnecting"
    DISCONNECTED = "disconnected"
    ERROR = "error"


@dataclass(frozen=True, slots=True)
class CanIdFilter:
    can_id: int
    is_extended_id: bool


@dataclass(frozen=True, slots=True)
class FilterConfig:
    mode: FilterMode
    ids: tuple[CanIdFilter, ...] = ()
    _keys: frozenset[tuple[int, bool]] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "_keys",
            frozenset((item.can_id, item.is_extended_id) for item in self.ids),
        )

    def as_python_can(self) -> list[dict[str, int | bool]] | None:
        if self.mode is not FilterMode.WHITELIST or not self.ids:
            return None
        return [
            {
                "can_id": item.can_id,
                "can_mask": 0x1FFFFFFF if item.is_extended_id else 0x7FF,
                "extended": item.is_extended_id,
            }
            for item in self.ids
        ]

    def allows(self, frame: CanFrame) -> bool:
        if self.mode is FilterMode.ALL:
            return True
        listed = (frame.can_id, frame.is_extended_id) in self._keys
        return listed if self.mode is FilterMode.WHITELIST else not listed


@dataclass(frozen=True, slots=True)
class CanInterfaceInfo:
    name: str
    kind: str
    administratively_up: bool | None = None
    operational_state: str | None = None
    can_state: str | None = None
    bitrate: int | None = None
    data_bitrate: int | None = None
    fd_enabled: bool | None = None
    fd_capable: bool | None = None
    mtu: int | None = None


@dataclass(frozen=True, slots=True)
class CanFrame:
    capture_timestamp_ns: int
    ingress_monotonic_ns: int
    interface: str
    can_id: int
    is_extended_id: bool
    is_fd: bool
    dlc: int
    data: bytes
    direction: Direction
    is_error_frame: bool = False
    is_remote_frame: bool = False
    bitrate_switch: bool | None = None
    error_state_indicator: bool | None = None


@dataclass(frozen=True, slots=True)
class SendFrameCommand:
    can_id: int
    is_extended_id: bool
    is_fd: bool
    data: bytes


@dataclass(frozen=True, slots=True)
class CapturedFrame:
    sequence: int
    filter_revision: int
    frame: CanFrame

    def to_wire(self) -> dict[str, object]:
        frame = self.frame
        return {
            "sequence": self.sequence,
            "timestamp_ns": str(frame.capture_timestamp_ns),
            "timestamp_source": "kernel_software_realtime_float_converted",
            "ingress_monotonic_ns": str(frame.ingress_monotonic_ns),
            "interface": frame.interface,
            "can_id": frame.can_id,
            "is_extended_id": frame.is_extended_id,
            "is_fd": frame.is_fd,
            "dlc": frame.dlc,
            "data_hex": frame.data.hex().upper(),
            "direction": frame.direction.value,
            "is_error_frame": frame.is_error_frame,
            "is_remote_frame": frame.is_remote_frame,
            "bitrate_switch": frame.bitrate_switch if frame.is_fd else None,
            "error_state_indicator": (
                frame.error_state_indicator if frame.is_fd else None
            ),
            "filter_revision": self.filter_revision,
        }
