"""Online timing statistics with an explicit adjacent-period jitter formula."""

from __future__ import annotations

import math
from dataclasses import dataclass

from can_monitor.domain.models import CanFrame


@dataclass(slots=True)
class TimingStats:
    frame_count: int = 0
    interval_count: int = 0
    last_timestamp_ns: int | None = None
    last_interval_ns: int | None = None
    min_interval_ns: int | None = None
    max_interval_ns: int | None = None
    mean_interval_ns: float = 0.0
    m2: float = 0.0
    adjacent_jitter_sum_ns: int = 0
    adjacent_jitter_samples: int = 0
    clock_discontinuities: int = 0

    def observe(self, timestamp_ns: int) -> None:
        self.frame_count += 1
        previous_timestamp = self.last_timestamp_ns
        self.last_timestamp_ns = timestamp_ns
        if previous_timestamp is None:
            return
        interval = timestamp_ns - previous_timestamp
        if interval < 0:
            self.clock_discontinuities += 1
            self.last_interval_ns = None
            return

        previous_interval = self.last_interval_ns
        self.last_interval_ns = interval
        self.interval_count += 1
        self.min_interval_ns = (
            interval if self.min_interval_ns is None else min(self.min_interval_ns, interval)
        )
        self.max_interval_ns = (
            interval if self.max_interval_ns is None else max(self.max_interval_ns, interval)
        )
        delta = interval - self.mean_interval_ns
        self.mean_interval_ns += delta / self.interval_count
        self.m2 += delta * (interval - self.mean_interval_ns)
        if previous_interval is not None:
            self.adjacent_jitter_sum_ns += abs(interval - previous_interval)
            self.adjacent_jitter_samples += 1

    def snapshot(self) -> dict[str, int | float | None | str]:
        standard_deviation = (
            math.sqrt(self.m2 / (self.interval_count - 1))
            if self.interval_count > 1
            else None
        )
        jitter = (
            self.adjacent_jitter_sum_ns / self.adjacent_jitter_samples
            if self.adjacent_jitter_samples
            else None
        )
        frequency = (
            1_000_000_000 / self.mean_interval_ns if self.mean_interval_ns > 0 else None
        )
        return {
            "frame_count": self.frame_count,
            "interval_count": self.interval_count,
            "last_interval_ns": self.last_interval_ns,
            "min_interval_ns": self.min_interval_ns,
            "max_interval_ns": self.max_interval_ns,
            "mean_interval_ns": self.mean_interval_ns if self.interval_count else None,
            "standard_deviation_ns": standard_deviation,
            "jitter_ns": jitter,
            "jitter_definition": "mean(abs(interarrival[i] - interarrival[i-1]))",
            "interval_clock": "ingress_monotonic",
            "observed_frequency_hz": frequency,
            "clock_discontinuities": self.clock_discontinuities,
        }


class TimingAnalyzer:
    def __init__(self) -> None:
        self._stats: dict[tuple[str, int, bool, bool], TimingStats] = {}

    def observe(self, frame: CanFrame) -> None:
        if frame.is_error_frame or frame.is_remote_frame:
            return
        key = (frame.interface, frame.can_id, frame.is_extended_id, frame.is_fd)
        self._stats.setdefault(key, TimingStats()).observe(frame.ingress_monotonic_ns)

    def snapshot(self) -> list[dict[str, object]]:
        result: list[dict[str, object]] = []
        for (interface, can_id, extended, fd), stats in sorted(self._stats.items()):
            result.append(
                {
                    "interface": interface,
                    "can_id": can_id,
                    "is_extended_id": extended,
                    "is_fd": fd,
                    **stats.snapshot(),
                }
            )
        return result
