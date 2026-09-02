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


def test_physical_tx_defaults_to_disabled_and_reads_enabled_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("CAN_MONITOR_TX_ENABLED", raising=False)
    assert Settings.from_env().tx_enabled is False
    monkeypatch.setenv("CAN_MONITOR_TX_ENABLED", "true")
    assert Settings.from_env().tx_enabled is True
    assert Settings(tx_enabled=True).tx_enabled is True


def test_cors_origins_must_be_absolute_http_origins() -> None:
    with pytest.raises(ValueError, match="Invalid CORS origin"):
        Settings(cors_origins=("*",))
