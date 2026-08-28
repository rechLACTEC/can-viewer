"""Read-only Linux SocketCAN interface discovery and metadata enrichment."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import subprocess
from pathlib import Path

import can

from can_monitor.domain.models import CanInterfaceInfo

logger = logging.getLogger(__name__)
_SAFE_INTERFACE = re.compile(r"^[A-Za-z0-9_.:-]{1,32}$")
_ARPHRD_CAN = 280
_CANFD_MTU = 72


def _read_int(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return None


def _read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="ascii").strip()
    except OSError:
        return None


def _ip_metadata(name: str) -> dict[str, object]:
    try:
        result = subprocess.run(
            ["ip", "-details", "-json", "link", "show", "dev", name],
            check=True,
            capture_output=True,
            text=True,
            timeout=1,
        )
        entries = json.loads(result.stdout)
        return entries[0] if entries else {}
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, IndexError):
        return {}


def _discover_sync() -> list[CanInterfaceInfo]:
    try:
        configs = can.detect_available_configs(interfaces=["socketcan"])
    except (can.CanError, OSError) as error:
        logger.warning("SocketCAN discovery failed: %s", error)
        return []

    interfaces: list[CanInterfaceInfo] = []
    seen: set[str] = set()
    for config in configs:
        channel = config.get("channel")
        if not isinstance(channel, str) or not _SAFE_INTERFACE.fullmatch(channel):
            continue
        if channel in seen:
            continue
        seen.add(channel)

        sysfs = Path("/sys/class/net") / channel
        link_type = _read_int(sysfs / "type")
        if link_type is not None and link_type != _ARPHRD_CAN:
            continue
        ip_data = _ip_metadata(channel)
        link_info = ip_data.get("linkinfo", {})
        if not isinstance(link_info, dict):
            link_info = {}
        info_data = link_info.get("info_data", {})
        if not isinstance(info_data, dict):
            info_data = {}
        kind = str(link_info.get("info_kind") or "unknown")
        mtu_raw = ip_data.get("mtu")
        mtu = mtu_raw if isinstance(mtu_raw, int) else _read_int(sysfs / "mtu")
        flags = ip_data.get("flags", [])
        administratively_up = "UP" in flags if isinstance(flags, list) else None
        operational_state = (
            str(ip_data["operstate"]).lower()
            if ip_data.get("operstate") is not None
            else _read_text(sysfs / "operstate")
        )
        interfaces.append(
            CanInterfaceInfo(
                name=channel,
                kind=kind,
                administratively_up=administratively_up,
                operational_state=operational_state,
                can_state=(
                    str(info_data["state"]).lower()
                    if info_data.get("state") is not None
                    else None
                ),
                bitrate=(
                    info_data["bitrate"]
                    if isinstance(info_data.get("bitrate"), int)
                    else None
                ),
                data_bitrate=(
                    info_data["data_bitrate"]
                    if isinstance(info_data.get("data_bitrate"), int)
                    else None
                ),
                fd_enabled=mtu == _CANFD_MTU if mtu is not None else None,
                fd_capable=None,
                mtu=mtu,
            )
        )
    return sorted(interfaces, key=lambda item: item.name)


class LinuxCanInterfaceDiscoverer:
    async def discover(self) -> list[CanInterfaceInfo]:
        return await asyncio.to_thread(_discover_sync)
