#!/usr/bin/env python3
"""DNS/panel gecikme + kim-evde — state.json / Prometheus textfile."""
from __future__ import annotations

import json
import os
import socket
import statistics
import struct
import time
import urllib.error
import urllib.request
from typing import Any


def _dns_query_ms(server: str = "127.0.0.1", name: str = "example.com", timeout: float = 2.0) -> int:
    """Minimal DNS A query — stdlib only. Fail → -1."""
    labels = name.encode("ascii").split(b".")
    qname = b"".join(bytes([len(x)]) + x for x in labels) + b"\x00"
    tid = os.getpid() & 0xFFFF
    header = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    question = qname + struct.pack("!HH", 1, 1)
    payload = header + question
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    t0 = time.perf_counter()
    try:
        sock.sendto(payload, (server, 53))
        data, _ = sock.recvfrom(512)
        ms = int((time.perf_counter() - t0) * 1000)
        if len(data) < 12:
            return -1
        rtid, flags = struct.unpack("!HH", data[:4])
        if rtid != tid or (flags & 0x000F) != 0:
            return -1
        return max(ms, 0)
    except (OSError, TimeoutError, struct.error):
        return -1
    finally:
        sock.close()


def _http_ms(url: str, timeout: float = 3.0) -> int:
    t0 = time.perf_counter()
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "pi-gateway-probe"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            resp.read(64)
        return max(int((time.perf_counter() - t0) * 1000), 0)
    except urllib.error.HTTPError as exc:
        if exc.code in (200, 301, 302, 401, 403):
            return max(int((time.perf_counter() - t0) * 1000), 0)
        return -1
    except (OSError, TimeoutError, ValueError):
        return -1


def _median_dns_ms(names: tuple[str, ...], samples: int = 3) -> tuple[int, int]:
    values: list[int] = []
    failures = 0
    for name in names:
        for _ in range(samples):
            value = _dns_query_ms(name=name)
            if value < 0:
                failures += 1
            else:
                values.append(value)
    return (int(statistics.median(values)) if values else -1, failures)


def _who_home() -> tuple[int, str, bool]:
    remote = os.environ.get("REMOTE_DIR", os.path.expanduser("~/pi-gateway"))
    db = os.path.join(remote, "data", "netalertx", "db", "app.db")
    py = os.path.join(os.path.dirname(__file__), "netalert-devices.py")
    if not os.path.isfile(db) or not os.path.isfile(py):
        return 0, "", False
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location("netalert_devices", py)
        if spec is None or spec.loader is None:
            return 0, "", False
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        devices = mod.online_devices(db)
        names = [d.get("name") or d.get("ip") or "?" for d in devices]
        return len(names), ", ".join(names[:12]), True
    except Exception:
        return 0, "", False


def probe() -> dict[str, Any]:
    dns_ms, dns_failures = _median_dns_ms(("example.com",), samples=3)
    video_dns_ms, video_dns_failures = _median_dns_ms(
        ("googlevideo.com", "ytimg.com"), samples=2
    )
    port = os.environ.get("ADGUARD_WEB_PORT", "8080")
    panel_ms = _http_ms(f"http://127.0.0.1:{port}/")
    n, who, readable = _who_home()
    return {
        "dns_latency_ms": dns_ms,
        "dns_probe_failures": dns_failures,
        "video_dns_latency_ms": video_dns_ms,
        "video_dns_probe_failures": video_dns_failures,
        "panel_latency_ms": panel_ms,
        "hosts_online": n,
        "who_home": who,
        "netalert_db_readable": readable,
    }


def prom_lines(data: dict[str, Any]) -> str:
    return (
        "# HELP pi_gateway_dns_latency_ms Local DNS A query latency (-1 fail)\n"
        "# TYPE pi_gateway_dns_latency_ms gauge\n"
        f"pi_gateway_dns_latency_ms {int(data.get('dns_latency_ms', -1))}\n"
        "# HELP pi_gateway_dns_probe_failures DNS probe failures in current sample\n"
        "# TYPE pi_gateway_dns_probe_failures gauge\n"
        f"pi_gateway_dns_probe_failures {int(data.get('dns_probe_failures', 0))}\n"
        "# HELP pi_gateway_video_dns_latency_ms Median local DNS latency for video host samples\n"
        "# TYPE pi_gateway_video_dns_latency_ms gauge\n"
        f"pi_gateway_video_dns_latency_ms {int(data.get('video_dns_latency_ms', -1))}\n"
        "# HELP pi_gateway_video_dns_probe_failures Video DNS probe failures in current sample\n"
        "# TYPE pi_gateway_video_dns_probe_failures gauge\n"
        f"pi_gateway_video_dns_probe_failures {int(data.get('video_dns_probe_failures', 0))}\n"
        "# HELP pi_gateway_panel_latency_ms AdGuard UI HTTP latency (-1 fail)\n"
        "# TYPE pi_gateway_panel_latency_ms gauge\n"
        f"pi_gateway_panel_latency_ms {int(data.get('panel_latency_ms', -1))}\n"
        "# HELP pi_gateway_hosts_online NetAlertX present-device count\n"
        "# TYPE pi_gateway_hosts_online gauge\n"
        f"pi_gateway_hosts_online {int(data.get('hosts_online', 0))}\n"
        "# HELP pi_gateway_netalert_db_readable 1 when NetAlertX SQLite is readable\n"
        "# TYPE pi_gateway_netalert_db_readable gauge\n"
        f"pi_gateway_netalert_db_readable {int(bool(data.get('netalert_db_readable', False)))}\n"
    )


def self_check() -> None:
    q = b"".join(bytes([len(x)]) + x for x in b"example.com".split(b".")) + b"\x00"
    assert q.startswith(b"\x07example")
    lines = prom_lines(
        {
            "dns_latency_ms": 12,
            "panel_latency_ms": 80,
            "hosts_online": 3,
            "netalert_db_readable": True,
        }
    )
    assert "pi_gateway_dns_latency_ms 12" in lines
    assert "pi_gateway_video_dns_latency_ms -1" in lines
    assert "pi_gateway_netalert_db_readable 1" in lines
    from unittest.mock import patch

    with patch(
        f"{__name__}._dns_query_ms",
        side_effect=[30, 10, 20],
    ):
        assert _median_dns_ms(("example.com",), samples=3) == (20, 0)
    print("[gateway-probes] self-check OK")


if __name__ == "__main__":
    import sys

    if "--self-check" in sys.argv:
        self_check()
        raise SystemExit(0)
    data = probe()
    if "--json" in sys.argv:
        json.dump(data, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
    else:
        sys.stdout.write(prom_lines(data))
        json.dump(data, sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
