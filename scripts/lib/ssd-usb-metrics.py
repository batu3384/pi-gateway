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
FSCK_STATE_PATH = os.environ.get(
    "SSD_FSCK_STATE_PATH",
    "/var/lib/pi-gateway/ssd-fsck-state.json",
)
FLAP_QUIET_CLEAR_SEC = int(
    os.environ.get("SSD_USB_FLAP_QUIET_CLEAR_SEC", "7200") or "7200"
)


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


def _fsck_baseline_ts() -> float:
    try:
        data = json.loads(Path(FSCK_STATE_PATH).read_text(encoding="utf-8"))
        val = float(data.get("last_success_at") or 0)
        if 0 < val <= time.time():
            return val
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        pass
    return 0.0


def _active_ssd_usb_bus_prefix() -> str | None:
    src = _run(["findmnt", "-n", "-o", "SOURCE", "/mnt/ssd"], timeout=3.0).strip()
    m_dev = re.match(r"^/dev/(sd[a-z]+)\d*$", src)
    if not m_dev:
        return None
    try:
        resolved = str(Path(f"/sys/block/{m_dev.group(1)}/device").resolve())
    except OSError:
        return None
    m_bus = re.search(r"/usb\d+/(\d+)-\d+", resolved)
    return f"{m_bus.group(1)}-" if m_bus else None


def _classify_kernel_line(
    line: str, usb_bus_prefix: str | None = None
) -> tuple[bool, bool]:
    low = line.lower()
    m_bus = re.search(r"\busb\s*(\d+)-|\busb(\d+)-port", low)
    if m_bus:
        bus_num = m_bus.group(1) or m_bus.group(2)
        expected_bus = usb_bus_prefix.rstrip("-") if usb_bus_prefix else "2"
        if bus_num != expected_bus:
            return False, False
    has_sd = bool(re.search(r"\bsd[a-z]+\d*\b", low))
    if "usb" not in low and not has_sd:
        return False, False
    is_reset = ("usb" in low) and any(
        x in low
        for x in (
            "usb disconnect",
            "cannot enable",
            "device not accepting address",
            "reset high-speed",
            "reset super speed",
            "reset superspeed",
        )
    )
    is_io = has_sd and ("i/o error" in low or "device offline error" in low)
    return is_reset, is_io


def count_kernel_usb_events(window_sec: int) -> tuple[int, int, float]:
    """journalctl -k — locale-safe, C-level grep to skip firewall/noise floods."""
    hours = max(1, (window_sec + 3599) // 3600)
    base_cmd = [
        "journalctl",
        "-k",
        "--since",
        f"{hours} hours ago",
        "-o",
        "short-iso",
        "--no-pager",
        "-q",
    ]
    out = ""
    try:
        proc = subprocess.run(
            [*base_cmd, "-g", "usb|sd[a-z]|i/o error|offline error"],
            text=True,
            capture_output=True,
            timeout=20.0,
        )
        if proc.returncode == 1 and not proc.stderr.strip():
            return 0, 0, 0.0
        if proc.returncode == 0:
            out = proc.stdout
        else:
            out = _run(base_cmd, timeout=20.0)
    except (subprocess.SubprocessError, OSError):
        out = _run(base_cmd, timeout=20.0)
    if not out:
        return 0, 0, 0.0
    cutoff = max(time.time() - window_sec, _fsck_baseline_ts())
    usb_prefix = _active_ssd_usb_bus_prefix()
    resets = io_err = 0
    last_event_ts = 0.0
    for line in out.splitlines():
        ts = _parse_journal_ts(line)
        if ts is None or ts <= cutoff:
            continue
        is_r, is_io = _classify_kernel_line(line, usb_prefix)
        if is_r:
            resets += 1
        if is_io:
            io_err += 1
        if is_r or is_io:
            last_event_ts = max(last_event_ts, ts)
    return resets, io_err, last_event_ts


def load_state() -> dict[str, Any]:
    try:
        with open(STATE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _atomic_install(path: Path, text: str, mode: str = "644") -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(
            prefix=".pi-gw-", suffix=".tmp", dir=str(path.parent), text=True
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.chmod(tmp_path, int(mode, 8))
            Path(tmp_path).replace(path)
            return
        finally:
            Path(tmp_path).unlink(missing_ok=True)
    except OSError:
        pass

    fd, tmp_path = tempfile.mkstemp(prefix="pi-gw-", suffix=".tmp", dir="/tmp", text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        try:
            os.chmod(tmp_path, int(mode, 8))
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


def _threshold_met(delta: int, resets: int, io_err: int) -> bool:
    return delta >= CRC_WARN_DELTA or resets >= RESET_WARN_COUNT or io_err >= IO_WARN_COUNT


def _should_alert_flap(
    delta: int, resets: int, io_err: int, last_event_ts: float, now_ts: float
) -> bool:
    if not _threshold_met(delta, resets, io_err):
        return False
    if delta >= CRC_WARN_DELTA:
        return True
    if last_event_ts <= 0:
        return False
    if FLAP_QUIET_CLEAR_SEC > 0 and (now_ts - last_event_ts) >= FLAP_QUIET_CLEAR_SEC:
        return False
    return True


def update(smart_text: str = "") -> dict[str, Any]:
    prev = load_state()
    crc = parse_crc(smart_text) if smart_text else prev.get("crc")
    if crc is None and not smart_text:
        crc = prev.get("crc")
    resets, io_err, last_event_ts = count_kernel_usb_events(WINDOW_SEC)
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
        "last_event_ts": int(last_event_ts) if last_event_ts > 0 else 0,
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
    last_event_ts = float(state.get("last_event_ts") or 0.0)
    # Root calisirken kendi kardes privileged kopyasini kullan (user-writable $REMOTE_DIR'e dusme)
    self_notify = Path(__file__).resolve().parent / "notify.sh"
    if self_notify.is_file():
        notify_sh = str(self_notify)
    else:
        remote = os.environ.get("REMOTE_DIR", os.path.expanduser("~/pi-gateway"))
        notify_sh = os.path.join(remote, "scripts/lib/notify.sh")
    if not os.path.isfile(notify_sh):
        return 0

    def _notify(fn: str, extra_env: dict[str, str] | None = None) -> bool:
        env = os.environ.copy()
        if extra_env:
            env.update(extra_env)
        try:
            subprocess.run(
                ["bash", "-c", f'source "{notify_sh}"; {fn}'],
                env=env,
                check=False,
                timeout=30,
            )
            return True
        except (subprocess.SubprocessError, OSError):
            return False

    if not _should_alert_flap(delta, resets, io_err, last_event_ts, time.time()):
        # last_alert_sig yokken de asili fail state temizlensin
        if not _notify("notify_ssd_usb_flap_ok"):
            return 1
        state["last_alert_sig"] = None
        save_state(state)
        return 0

    # Tam sayi imza yok — her I/O +1 Telegram spam olmasin. Repeat notify.sh.
    detail = f"CRC +{delta}, USB reset {resets}, I/O {io_err} (son {WINDOW_SEC // 3600}s)"
    if not _notify('notify_ssd_usb_flap "$SSD_USB_NOTIFY_DETAIL"', {"SSD_USB_NOTIFY_DETAIL": detail}):
        return 1
    state["last_alert_sig"] = "fail"
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
    assert _classify_kernel_line("2026-11-18T12:58:31+0300 batu kernel: usb 1-1.1: USB disconnect, device number 5") == (False, False)
    assert _classify_kernel_line("2026-11-18T01:00:23+0300 batu kernel: usb usb2-port2: Cannot enable. Maybe the USB cable is bad?") == (True, False)
    assert _classify_kernel_line("2026-11-18T01:00:23+0300 batu kernel: usb 2-2: reset SuperSpeed USB device number 7") == (True, False)
    assert _classify_kernel_line("2026-11-18T01:00:37+0300 batu kernel: I/O error, dev sdc, sector 123") == (False, True)
    assert _should_alert_flap(0, 19, 45, 1000.0, 1300.0)
    assert not _should_alert_flap(0, 19, 45, 1000.0, 1000.0 + FLAP_QUIET_CLEAR_SEC + 1)
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
