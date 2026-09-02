from can_monitor.domain.models import (
    CanFrame,
    CanIdFilter,
    Direction,
    FilterConfig,
    FilterMode,
)
from can_monitor.domain.timing import TimingAnalyzer, TimingStats


def _frame(
    timestamp: int, *, monotonic: int | None = None, error: bool = False
) -> CanFrame:
    return CanFrame(
        capture_timestamp_ns=timestamp,
        ingress_monotonic_ns=timestamp if monotonic is None else monotonic,
        interface="vcan0",
        can_id=0x123,
        is_extended_id=False,
        is_fd=False,
        dlc=1,
        data=b"\x01",
        direction=Direction.RX,
        is_error_frame=error,
    )


def test_exact_filters_keep_standard_and_extended_distinct() -> None:
    filters = FilterConfig(
        FilterMode.WHITELIST,
        (CanIdFilter(0x123, False), CanIdFilter(0x123, True)),
    ).as_python_can()
    assert filters == [
        {"can_id": 0x123, "can_mask": 0x7FF, "extended": False},
        {"can_id": 0x123, "can_mask": 0x1FFFFFFF, "extended": True},
    ]
    assert FilterConfig(FilterMode.ALL).as_python_can() is None


def test_all_whitelist_and_blacklist_share_exact_std_ext_matching() -> None:
    standard = _frame(1)
    extended_same_id = CanFrame(
        capture_timestamp_ns=2,
        ingress_monotonic_ns=2,
        interface="vcan0",
        can_id=0x123,
        is_extended_id=True,
        is_fd=False,
        dlc=1,
        data=b"\x02",
        direction=Direction.RX,
    )
    other = CanFrame(
        capture_timestamp_ns=3,
        ingress_monotonic_ns=3,
        interface="vcan0",
        can_id=0x456,
        is_extended_id=False,
        is_fd=False,
        dlc=1,
        data=b"\x03",
        direction=Direction.RX,
    )
    ids = (CanIdFilter(0x123, False),)

    assert FilterConfig(FilterMode.ALL).allows(standard)
    assert FilterConfig(FilterMode.WHITELIST, ids).allows(standard)
    assert not FilterConfig(FilterMode.WHITELIST, ids).allows(extended_same_id)
    assert not FilterConfig(FilterMode.WHITELIST, ids).allows(other)
    assert not FilterConfig(FilterMode.BLACKLIST, ids).allows(standard)
    assert FilterConfig(FilterMode.BLACKLIST, ids).allows(extended_same_id)
    assert FilterConfig(FilterMode.BLACKLIST, ids).allows(other)
    assert not FilterConfig(FilterMode.WHITELIST).allows(other)
    assert FilterConfig(FilterMode.BLACKLIST).allows(other)
    assert FilterConfig(FilterMode.BLACKLIST, ids).as_python_can() is None


def test_online_timing_and_explicit_jitter_formula() -> None:
    stats = TimingStats()
    for timestamp in (0, 10, 22, 32):
        stats.observe(timestamp)
    result = stats.snapshot()
    assert result["frame_count"] == 4
    assert result["interval_count"] == 3
    assert result["last_interval_ns"] == 10
    assert result["min_interval_ns"] == 10
    assert result["max_interval_ns"] == 12
    assert result["mean_interval_ns"] == 32 / 3
    assert result["jitter_ns"] == 2
    assert result["jitter_definition"] == "mean(abs(interarrival[i] - interarrival[i-1]))"
    assert result["interval_clock"] == "ingress_monotonic"


def test_clock_discontinuity_and_error_frames_are_observable_not_analyzed() -> None:
    stats = TimingStats()
    stats.observe(100)
    stats.observe(90)
    assert stats.snapshot()["clock_discontinuities"] == 1

    analyzer = TimingAnalyzer()
    analyzer.observe(_frame(1, error=True))
    assert analyzer.snapshot() == []
    analyzer.observe(_frame(2))
    assert analyzer.snapshot()[0]["frame_count"] == 1


def test_analyzer_uses_monotonic_ingress_not_wall_clock() -> None:
    analyzer = TimingAnalyzer()
    analyzer.observe(_frame(5_000, monotonic=100))
    analyzer.observe(_frame(1_000, monotonic=110))
    result = analyzer.snapshot()[0]
    assert result["last_interval_ns"] == 10
    assert result["clock_discontinuities"] == 0
