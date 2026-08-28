"""Runtime configuration loaded from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from urllib.parse import urlsplit


def _bool_env(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True, slots=True)
class Settings:
    tx_enabled: bool = False
    virtual_tx_enabled: bool = True
    physical_tx_token: str | None = field(default=None, repr=False)
    tx_rate_limit_per_second: int = 10
    acquisition_queue_size: int = 8192
    trace_buffer_size: int = 10_000
    client_queue_size: int = 2048
    websocket_batch_size: int = 200
    websocket_batch_interval_ms: int = 20
    cors_origins: tuple[str, ...] = (
        "http://localhost:3000",
        "http://localhost:5173",
        "http://localhost:8080",
    )
    log_level: str = "INFO"

    def __post_init__(self) -> None:
        limits = {
            "acquisition_queue_size": (self.acquisition_queue_size, 1_000_000),
            "trace_buffer_size": (self.trace_buffer_size, 1_000_000),
            "client_queue_size": (self.client_queue_size, 100_000),
            "websocket_batch_size": (self.websocket_batch_size, 10_000),
            "websocket_batch_interval_ms": (
                self.websocket_batch_interval_ms,
                60_000,
            ),
            "tx_rate_limit_per_second": (self.tx_rate_limit_per_second, 10_000),
        }
        for name, (value, maximum) in limits.items():
            if not 1 <= value <= maximum:
                raise ValueError(f"{name} must be between 1 and {maximum}")
        if self.tx_enabled and (
            self.physical_tx_token is None or len(self.physical_tx_token) < 16
        ):
            raise ValueError(
                "CAN_MONITOR_PHYSICAL_TX_TOKEN must contain at least 16 characters "
                "when physical transmission is enabled"
            )
        for origin in self.cors_origins:
            parsed = urlsplit(origin)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise ValueError(f"Invalid CORS origin: {origin!r}")

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            tx_enabled=_bool_env("CAN_MONITOR_TX_ENABLED", False),
            virtual_tx_enabled=_bool_env("CAN_MONITOR_VIRTUAL_TX_ENABLED", True),
            physical_tx_token=os.getenv("CAN_MONITOR_PHYSICAL_TX_TOKEN") or None,
            tx_rate_limit_per_second=int(
                os.getenv("CAN_MONITOR_TX_RATE_LIMIT_PER_SECOND", "10")
            ),
            acquisition_queue_size=int(
                os.getenv("CAN_MONITOR_ACQUISITION_QUEUE_SIZE", "8192")
            ),
            trace_buffer_size=int(os.getenv("CAN_MONITOR_TRACE_BUFFER_SIZE", "10000")),
            client_queue_size=int(os.getenv("CAN_MONITOR_CLIENT_QUEUE_SIZE", "2048")),
            websocket_batch_size=int(os.getenv("CAN_MONITOR_WS_BATCH_SIZE", "200")),
            websocket_batch_interval_ms=int(
                os.getenv("CAN_MONITOR_WS_BATCH_INTERVAL_MS", "20")
            ),
            cors_origins=tuple(
                origin.strip()
                for origin in os.getenv(
                    "CAN_MONITOR_CORS_ORIGINS",
                    "http://localhost:3000,http://localhost:5173,http://localhost:8080",
                ).split(",")
                if origin.strip()
            ),
            log_level=os.getenv("CAN_MONITOR_LOG_LEVEL", "INFO").upper(),
        )
