#!/usr/bin/env python3
"""SSD USB metrics — SMART CRC trend + dmesg reset/I/O counter."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STATE_PATH = os.environ.get(
    "SSD_USB_METRICS_STATE",
    "/var/lib/pi-gateway/ssd-usb-metrics-state.json",
)
METRICS_PATH = os.environ.get(
    "SSD_USB_METRICS_PROM",
    "/var/lib/pi-gateway/metrics/ssd_usb.prom",
)
WINDOW_SEC = int(os.environ.get("SSD_USB_DMESG_WINDOW_SEC", "86400") or "86400")
CRC_WARN_DELTA = int(os.environ.get("SSD_USB_CRC_WARN_DELTA", "5") or "5")
RESET_WARN_COUNT = int(os.environ.get("SSD_USB_RESET_WARN_COUNT", "3") or "3")


def _run(cmd: list[str], timeout: float = 8.0) -> str:
    try:
        return subprocess.check_output(
            cmd, text=True, timeout=timeout, stderr=subprocess.DEVNULL
        )
    except (subprocess.SubprocessError, OSError, ValueError):
        return ""


def parse_crc(text: str) -> int | None:
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 10 or not parts[0].isdigit():
            continue
        name, raw = parts[1], parts[-1]
        if name in (
            "UDMA_CRC_Error_Count",
            "Interface_CRC",
            "CRC_Error_Count",
            "Ultra_CRC_Error_Count",
        ):
            try:
                return int(re.sub(r"[^0-9]", "", raw) or "0")
            except ValueError:
                continue
    return None


def count_dmesg_events(window_sec: int) -> tuple[int, int]:
    """Return (usb_reset_events, io_errors) in window."""
    out = _run(["dmesg", "-T"], timeout=12.0)
    if not out:
        return 0, 0
    cutoff = time.time() - window_sec
    resets = io_err = 0
    ts_re = re.compile(r"^\[[^\]]+\]")
    for line in out.splitlines():
        low = line.lower()
        if "usb" not in low and "sda" not in low and "sdb" not in low:
            continue
        m = ts_re.match(line)
        if not m:
            continue
        try:
            ts_txt = m.group(0).strip("[]")
            ts = datetime.strptime(ts_txt, "%a %b %d %H:%M:%S %Y").replace(
                tzinfo=timezone.utc
            ).timestamp()
        except ValueError:
            continue
        if ts < cutoff:
            continue
        if any(
            x in low
            for x in (
                "usb disconnect",
                "cannot enable",
                "device not accepting address",
                "reset high-speed",
                "reset super speed",
            )
        ):
            resets += 1
        if "i/o error" in low or "device offline error" in low:
            io_err += 1
    return resets, io_err


def load_state() -> dict[str, Any]:
    try:
        with open(STATE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(data: dict[str, Any]) -> None:
    path = Path(STATE_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    tmp.replace(path)


def prom_lines(crc: int | None, delta: int, resets: int, io_err: int) -> str:
    crc_v = crc if crc is not None else -1
    return (
        "# HELP pi_gateway_ssd_usb_crc_errors SMART CRC error count (-1 unknown)\n"
        "# TYPE pi_gateway_ssd_usb_crc_errors gauge\n"
        f"pi_gateway_ssd_usb_crc_errors {crc_v}\n"
        "# HELP pi_gateway_ssd_usb_crc_delta CRC increase since last sample\n"
        "# TYPE pi_gateway_ssd_usb_crc_delta gauge\n"
        f"pi_gateway_ssd_usb_crc_delta {max(0, delta)}\n"
        "# HELP pi_gateway_ssd_usb_reset_events_24h USB reset/disconnect events in window\n"
        "# TYPE pi_gateway_ssd_usb_reset_events_24h gauge\n"
        f"pi_gateway_ssd_usb_reset_events_24h {resets}\n"
        "# HELP pi_gateway_ssd_usb_io_errors_24h Block I/O errors in window\n"
        "# TYPE pi_gateway_ssd_usb_io_errors_24h gauge\n"
        f"pi_gateway_ssd_usb_io_errors_24h {io_err}\n"
    )


def write_prom(text: str) -> None:
    path = Path(METRICS_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def update(smart_text: str = "") -> dict[str, Any]:
    prev = load_state()
    crc = parse_crc(smart_text) if smart_text else prev.get("crc")
    if crc is None and not smart_text:
        crc = prev.get("crc")
    resets, io_err = count_dmesg_events(WINDOW_SEC)
    prev_crc = prev.get("crc")
    delta = 0
    if crc is not None and prev_crc is not None:
        delta = max(0, int(crc) - int(prev_crc))
    now = datetime.now(timezone.utc).isoformat()
    state = {
        "ts": now,
        "crc": crc,
        "crc_delta": delta,
        "usb_resets_24h": resets,
        "io_errors_24h": io_err,
        "window_sec": WINDOW_SEC,
    }
    save_state(state)
    write_prom(prom_lines(crc if isinstance(crc, int) else None, delta, resets, io_err))
    return state


def notify_if_needed(state: dict[str, Any]) -> int:
    delta = int(state.get("crc_delta") or 0)
    resets = int(state.get("usb_resets_24h") or 0)
    io_err = int(state.get("io_errors_24h") or 0)
    if delta < CRC_WARN_DELTA and resets < RESET_WARN_COUNT:
        return 0
    remote = os.environ.get("REMOTE_DIR", os.path.expanduser("~/pi-gateway"))
    notify_sh = os.path.join(remote, "scripts/lib/notify.sh")
    if not os.path.isfile(notify_sh):
        return 0
    detail = f"CRC +{delta} (24s pencere), USB reset {resets}, I/O hata {io_err}"
    env = os.environ.copy()
    env["SSD_USB_NOTIFY_DETAIL"] = detail
    env["SSD_USB_CRC_DELTA"] = str(delta)
    env["SSD_USB_RESET_COUNT"] = str(resets)
    try:
        subprocess.run(
            ["bash", "-c", f'source "{notify_sh}"; notify_ssd_usb_flap "$SSD_USB_NOTIFY_DETAIL"'],
            env=env,
            check=False,
            timeout=30,
        )
    except (subprocess.SubprocessError, OSError):
        return 1
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    smart = ""
    if args.smart_file:
        try:
            smart = Path(args.smart_file).read_text(encoding="utf-8", errors="replace")
        except OSError:
            smart = ""
    elif args.smart:
        smart = args.smart
    state = update(smart)
    if args.notify:
        notify_if_needed(state)
    return 0


def cmd_export(_: argparse.Namespace) -> int:
    state = load_state()
    crc = state.get("crc")
    write_prom(
        prom_lines(
            int(crc) if isinstance(crc, int) else None,
            int(state.get("crc_delta") or 0),
            int(state.get("usb_resets_24h") or 0),
            int(state.get("io_errors_24h") or 0),
        )
    )
    return 0


def _self_check() -> None:
    assert parse_crc("199 UDMA_CRC_Error_Count 0x0032 100 32 0 0 0 0 38") == 38
    assert parse_crc("no crc here") is None
    prom = prom_lines(38, 2, 1, 0)
    assert "pi_gateway_ssd_usb_crc_errors 38" in prom
    print("[ssd-usb-metrics] self-check OK")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    up = sub.add_parser("update")
    up.add_argument("--smart")
    up.add_argument("--smart-file")
    up.add_argument("--notify", action="store_true")
    up.set_defaults(func=cmd_update)
    ex = sub.add_parser("export")
    ex.set_defaults(func=cmd_export)
    if "--self-check" in sys.argv:
        _self_check()
        return 0
    args = ap.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
