from can_monitor.infrastructure import discovery


def test_discovery_filters_non_can_sysfs_and_preserves_unknowns(monkeypatch) -> None:
    monkeypatch.setattr(
        discovery.can,
        "detect_available_configs",
        lambda interfaces: [
            {"interface": "socketcan", "channel": "vcan0"},
            {"interface": "socketcan", "channel": "eth0"},
        ],
    )

    def fake_read_int(path):
        if path.name == "type":
            return 280 if path.parent.name == "vcan0" else 1
        if path.name == "mtu":
            return 72
        return None

    monkeypatch.setattr(discovery, "_read_int", fake_read_int)
    monkeypatch.setattr(
        discovery,
        "_ip_metadata",
        lambda name: {
            "mtu": 72,
            "flags": ["UP"],
            "operstate": "UNKNOWN",
            "linkinfo": {"info_kind": "vcan", "info_data": {}},
        },
    )
    result = discovery._discover_sync()
    assert [item.name for item in result] == ["vcan0"]
    assert result[0].administratively_up is True
    assert result[0].operational_state == "unknown"
    assert result[0].fd_enabled is True
    assert result[0].fd_capable is None
