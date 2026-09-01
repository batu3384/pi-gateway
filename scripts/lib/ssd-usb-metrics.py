#!/usr/bin/env python3
"""SSD USB metrics — SMART CRC trend + kernel journal USB/I/O counter."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
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
IO_WARN_COUNT = int(os.environ.get("SSD_USB_IO_WARN_COUNT", "5") or "5")


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


def _parse_journal_ts(line: str) -> float | None:
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:?\d{2}|Z)?)", line)
    if not m:
        return None
    raw = m.group(1).replace("Z", "+00:00")
    if len(raw) >= 5 and raw[-5] in "+-" and raw[-3] != ":":
        raw = f"{raw[:-5]}{raw[-5:-2]}:{raw[-2:]}"
    try:
        return datetime.fromisoformat(raw).timestamp()
    except ValueError:
        return None


def count_kernel_usb_events(window_sec: int) -> tuple[int, int]:
    """journalctl -k — locale-safe (dmesg -T TR ay adlari parse etmez)."""
    hours = max(1, (window_sec + 3599) // 3600)
    out = _run(
        [
            "journalctl",
            "-k",
            "--since",
            f"{hours} hours ago",
            "-o",
            "short-iso",
            "--no-pager",
            "-q",
        ],
        timeout=20.0,
    )
    if not out:
        return 0, 0
    cutoff = time.time() - window_sec
    resets = io_err = 0
    for line in out.splitlines():
        ts = _parse_journal_ts(line)
        if ts is None or ts < cutoff:
            continue
        low = line.lower()
        if "usb" not in low and "sda" not in low and "sdb" not in low:
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


def _atomic_install(path: Path, text: str, mode: str = "644") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix="pi-gw-", suffix=".tmp", dir="/tmp", text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        try:
            Path(tmp_path).replace(path)
            return
        except OSError:
            subprocess.run(
                ["sudo", "install", "-m", mode, tmp_path, str(path)],
                check=True,
                timeout=10,
            )
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def save_state(data: dict[str, Any]) -> None:
    payload = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    _atomic_install(Path(STATE_PATH), payload)


def write_prom(text: str) -> None:
    _atomic_install(Path(METRICS_PATH), text)
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
    try:
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(path)
        return
    except OSError:
        pass
    try:
        subprocess.run(
            ["sudo", "install", "-m", "644", "-o", str(os.getuid()), "-g", str(os.getgid()), str(tmp), str(path)],
            check=True,
            timeout=10,
        )
        tmp.unlink(missing_ok=True)
    except (subprocess.SubprocessError, OSError):
        tmp.unlink(missing_ok=True)
        raise


def _alert_signature(delta: int, resets: int, io_err: int) -> str:
    return f"crc={delta}:r={resets}:io={io_err}"


def _threshold_met(delta: int, resets: int, io_err: int) -> bool:
    return delta >= CRC_WARN_DELTA or resets >= RESET_WARN_COUNT or io_err >= IO_WARN_COUNT


def update(smart_text: str = "") -> dict[str, Any]:
    prev = load_state()
    crc = parse_crc(smart_text) if smart_text else prev.get("crc")
    if crc is None and not smart_text:
        crc = prev.get("crc")
    resets, io_err = count_kernel_usb_events(WINDOW_SEC)
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
        "last_alert_sig": prev.get("last_alert_sig"),
    }
    save_state(state)
    write_prom(prom_lines(crc if isinstance(crc, int) else None, delta, resets, io_err))
    return state


def notify_if_needed(state: dict[str, Any]) -> int:
    delta = int(state.get("crc_delta") or 0)
    resets = int(state.get("usb_resets_24h") or 0)
    io_err = int(state.get("io_errors_24h") or 0)
    if not _threshold_met(delta, resets, io_err):
        return 0
    sig = _alert_signature(delta, resets, io_err)
    if sig == state.get("last_alert_sig"):
        return 0
    remote = os.environ.get("REMOTE_DIR", os.path.expanduser("~/pi-gateway"))
    notify_sh = os.path.join(remote, "scripts/lib/notify.sh")
    if not os.path.isfile(notify_sh):
        return 0
    detail = f"CRC +{delta}, USB reset {resets}, I/O {io_err} (son {WINDOW_SEC // 3600}s)"
    env = os.environ.copy()
    env["SSD_USB_NOTIFY_DETAIL"] = detail
    try:
        subprocess.run(
            ["bash", "-c", f'source "{notify_sh}"; notify_ssd_usb_flap "$SSD_USB_NOTIFY_DETAIL"'],
            env=env,
            check=False,
            timeout=30,
        )
    except (subprocess.SubprocessError, OSError):
        return 1
    state["last_alert_sig"] = sig
    save_state(state)
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
    ts = _parse_journal_ts("2026-09-01T11:45:37+0300 usb 2-2: USB disconnect")
    assert ts is not None
    prom = prom_lines(38, 2, 1, 0)
    assert "pi_gateway_ssd_usb_crc_errors 38" in prom
    assert _threshold_met(0, 3, 0)
    assert not _threshold_met(0, 2, 4)
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
