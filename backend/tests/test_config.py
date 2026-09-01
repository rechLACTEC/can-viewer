import pytest

from can_monitor.config import Settings


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("acquisition_queue_size", 0),
        ("trace_buffer_size", -1),
        ("client_queue_size", 100_001),
        ("websocket_batch_size", 10_001),
        ("websocket_batch_interval_ms", 0),
        ("tx_rate_limit_per_second", 0),
        ("recording_queue_size", 0),
        ("recording_max_bytes", 0),
    ],
)
def test_settings_reject_unsafe_resource_limits(field: str, value: int) -> None:
    with pytest.raises(ValueError, match=field):
        Settings(**{field: value})


def test_physical_tx_enabled_requires_long_token() -> None:
    with pytest.raises(ValueError, match="PHYSICAL_TX_TOKEN"):
        Settings(tx_enabled=True)
    with pytest.raises(ValueError, match="PHYSICAL_TX_TOKEN"):
        Settings(tx_enabled=True, physical_tx_token="short")
    assert Settings(
        tx_enabled=True, physical_tx_token="a-long-secret-token"
    ).tx_enabled


def test_cors_origins_must_be_absolute_http_origins() -> None:
    with pytest.raises(ValueError, match="Invalid CORS origin"):
        Settings(cors_origins=("*",))
