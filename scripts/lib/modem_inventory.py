#!/usr/bin/env python3
"""Shared reader for the last atomic modem inventory snapshot."""
from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from typing import Any

DEFAULT_STALE_SEC = 900
MAC_RE = re.compile(r"^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", re.I)
BAD_NAMES = frozenset({"", "?", "(name not found)", "unknown", "unknown device", "n/a", "-"})


def _usable_name(value: Any) -> str:
    name = str(value or "").strip()
    if (
        not name
        or name.lower() in BAD_NAMES
        or name.startswith("192.168.")
        or MAC_RE.fullmatch(name.replace("-", ":"))
    ):
        return ""
    return name[:128]


def _normalise_mac(value: Any) -> str:
    mac = str(value or "").strip().lower().replace("-", ":")
    return mac if MAC_RE.fullmatch(mac) else ""


def _privacy_mac(mac: str) -> bool:
    try:
        return bool(int(mac.split(":", 1)[0], 16) & 0x02)
    except (ValueError, IndexError):
        return False


def _as_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def _empty(path: str) -> dict[str, Any]:
    return {
        "path": path,
        "present": os.path.isfile(path),
        "fresh": False,
        "age": None,
        "fetched_at": None,
        "by_ip": {},
        "by_mac": {},
        "mac_by_ip": {},
        "devices_by_ip": {},
        "devices_by_mac": {},
        "ips": set(),
        "devices": [],
    }


def load_modem_inventory(path: str = "", stale_sec: int | None = None) -> dict[str, Any]:
    """Load snapshot and expose name plus provenance indexes.

    Stale or malformed snapshots remain readable for diagnostics but never
    provide fresh IP-based identity evidence.
    """
    resolved = path or os.environ.get("MODEM_INVENTORY_PATH") or os.path.join(
        os.environ.get("REMOTE_DIR", os.path.expanduser("~/pi-gateway")),
        "data",
        "modem-inventory.json",
    )
    snapshot = _empty(resolved)
    if stale_sec is None:
        try:
            stale_sec = int(
                os.environ.get("MODEM_INVENTORY_STALE_SEC", DEFAULT_STALE_SEC)
            )
        except (TypeError, ValueError):
            stale_sec = DEFAULT_STALE_SEC
    stale_sec = max(0, stale_sec)
    try:
        with open(resolved, encoding="utf-8") as handle:
            data = json.load(handle)
        if (
            not isinstance(data, dict)
            or data.get("schema_version") != 1
            or not isinstance(data.get("devices"), list)
        ):
            return snapshot
        fetched_at = datetime.fromisoformat(
            str(data.get("fetched_at", "")).replace("Z", "+00:00")
        )
        age = max(0, int(datetime.now(timezone.utc).timestamp() - fetched_at.timestamp()))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return snapshot

    devices: list[dict[str, Any]] = []
    by_ip: dict[str, str] = {}
    by_mac: dict[str, str] = {}
    mac_by_ip: dict[str, str] = {}
    devices_by_ip: dict[str, dict[str, Any]] = {}
    devices_by_mac: dict[str, dict[str, Any]] = {}
    ips: set[str] = set()
    for raw in data["devices"]:
        if not isinstance(raw, dict) or raw.get("active") is False:
            continue
        device = dict(raw)
        mac = _normalise_mac(device.get("mac"))
        ip = str(device.get("ip") or "").strip()
        name = _usable_name(device.get("name") or device.get("label"))
        if mac:
            device["mac"] = mac
        if ip:
            device["ip"] = ip
        if name:
            device["name"] = name
        elif "name" in device:
            device.pop("name", None)
        if not mac and not ip:
            continue
        device["privacy_mac"] = _as_bool(
            device.get("privacy_mac"), _privacy_mac(mac)
        )
        device.setdefault("confidence", "low" if not mac else "medium")
        device.setdefault("source", "zte-h3600p")
        device.setdefault("last_seen", data.get("fetched_at"))
        devices.append(device)
        if ip:
            ips.add(ip)
            if mac:
                mac_by_ip[ip] = mac
            devices_by_ip[ip] = device
            if name:
                by_ip[ip] = name
        if mac:
            devices_by_mac[mac] = device
            if name:
                by_mac[mac] = name

    snapshot.update(
        {
            "fresh": age <= stale_sec,
            "age": age,
            "fetched_at": data.get("fetched_at"),
            "devices": devices,
            "by_ip": by_ip,
            "by_mac": by_mac,
            "mac_by_ip": mac_by_ip,
            "devices_by_ip": devices_by_ip,
            "devices_by_mac": devices_by_mac,
            "ips": ips,
        }
    )
    return snapshot


def modem_device(
    inventory: dict[str, Any], mac: str = "", ip: str = ""
) -> dict[str, Any]:
    """Return MAC match, or fresh IP match, with provenance metadata."""
    mac_key = _normalise_mac(mac)
    ip_key = str(ip or "").strip()
    by_mac = inventory.get("devices_by_mac") or {}
    by_ip = inventory.get("devices_by_ip") or {}
    device = by_mac.get(mac_key) if mac_key else None
    if device is None and inventory.get("fresh") and ip_key:
        device = by_ip.get(ip_key)
    return device if isinstance(device, dict) else {}


def modem_name(inventory: dict[str, Any], mac: str = "", ip: str = "") -> str:
    device = modem_device(inventory, mac, ip)
    return _usable_name(device.get("name") or device.get("label"))


def self_check() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "modem-inventory.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "schema_version": 1,
                    "fetched_at": (
                        datetime.now(timezone.utc) - timedelta(seconds=2)
                    ).isoformat(),
                    "devices": [
                        {
                            "mac": "AA-BB-CC-DD-EE-01",
                            "ip": "192.168.1.50",
                            "name": "Telefon",
                            "source": "topology:TOPOLOGY",
                            "confidence": "high",
                            "privacy_mac": "false",
                            "last_seen": "2026-08-29T09:00:00+00:00",
                        }
                    ],
                },
                handle,
            )
        inventory = load_modem_inventory(path)
        device = modem_device(inventory, ip="192.168.1.50")
        assert inventory["fresh"] and device["mac"] == "aa:bb:cc:dd:ee:01"
        assert device["privacy_mac"] is False
        assert modem_name(inventory, ip="192.168.1.50") == "Telefon"
        stale = load_modem_inventory(path, stale_sec=0)
        assert not stale["fresh"] and not modem_device(stale, ip="192.168.1.50")
    print("[modem-inventory] self-check OK")


if __name__ == "__main__":
    import sys

    if "--self-check" in sys.argv:
        self_check()
