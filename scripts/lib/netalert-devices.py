#!/usr/bin/env python3
"""NetAlertX Events — yeni cihaz / offline okuma, state, format."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any

STATE_VERSION = 3
SKIP_MACS = frozenset({"internet"})
NOISE_MAC_PREFIXES = ("01:", "33:", "ff:")
BAD_NAMES = frozenset({"", "?", "(name not found)"})
STREAMS = {
    "new_device": "New Device",
    "offline": "Disconnected",
}


def _ts_local(ts: int | float | str | None) -> str:
    if ts is None:
        return "?"
    try:
        t = float(ts)
    except (TypeError, ValueError):
        return "?"
    return datetime.fromtimestamp(t).strftime("%d.%m.%Y %H:%M")


def _is_privacy_mac(mac: str) -> bool:
    parts = (mac or "").strip().lower().split(":")
    if len(parts) != 6:
        return False
    try:
        return (int(parts[0], 16) & 0x02) != 0
    except ValueError:
        return False


def suggest_display_name(
    name: str | None,
    vendor: str | None,
    dtype: str | None,
    ip: str | None,
    mac: str | None,
) -> str:
    ip = (ip or "").strip()
    mac = (mac or "").strip()
    name = (name or "").strip()
    vendor = (vendor or "").strip()
    dtype = (dtype or "").strip()

    if ip == "192.168.1.1":
        return "Router (ZTE)"
    if name and name not in BAD_NAMES and not name.startswith("192.168."):
        return name
    if mac in SKIP_MACS:
        return mac
    vl = vendor.lower()
    if "raspberry" in vl:
        return "Pi Gateway"
    if dtype == "Gateway" and "zte" in vl:
        return "Router (ZTE)"
    if "apple" in vl:
        return "Apple iPhone/iPad" if dtype == "Phone" else "Apple cihaz"
    if "samjin" in vl or "samsung" in vl:
        return "Samsung akıllı cihaz"
    if "locally administered" in vl or _is_privacy_mac(mac or ""):
        return "Gizlilik MAC (iPhone/Android/Mac)"
    if vendor and vendor not in ("(Unknown: locally administered)",):
        short = vendor.split(",")[0].strip()
        return f"{short} ({ip})" if ip else short
    if dtype:
        return f"{dtype} ({ip})" if ip else dtype
    return f"Cihaz {ip}" if ip else "Bilinmeyen cihaz"


def _is_noise_mac(mac: str, *, new_device: bool = False) -> bool:
    """Gizlilik/multicast MAC — yeni cihaz bildiriminde gürültü."""
    mac = (mac or "").strip().lower()
    if not mac or mac in SKIP_MACS:
        return True
    if new_device and _is_privacy_mac(mac):
        return True
    if new_device:
        for prefix in NOISE_MAC_PREFIXES:
            if mac.startswith(prefix):
                return True
    return False


def _open_db(path: str) -> sqlite3.Connection:
    try:
        return sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.OperationalError as exc:
        msg = str(exc).lower()
        if "unable to open database" in msg:
            print(
                "[netalert-devices] HATA: NetAlertX veritabani okunamadi (dosya izni). "
                "Cozum: bash scripts/pi/ensure-netalert-db-access.sh",
                file=sys.stderr,
            )
        else:
            print(f"[netalert-devices] HATA: veritabani: {exc}", file=sys.stderr)
        raise


def _empty_state() -> dict[str, Any]:
    return {
        "version": STATE_VERSION,
        "streams": {k: {"last_rowid": 0} for k in STREAMS},
    }


def _migrate_state(data: dict[str, Any]) -> dict[str, Any] | None:
    ver = data.get("version")
    if ver == STATE_VERSION:
        st = _empty_state()
        for stream in STREAMS:
            cur = (data.get("streams") or {}).get(stream) or {}
            st["streams"][stream]["last_rowid"] = int(cur.get("last_rowid") or 0)
        if data.get("bootstrapped_at"):
            st["bootstrapped_at"] = data["bootstrapped_at"]
        return st
    if ver == 2:
        st = _empty_state()
        st["streams"]["new_device"]["last_rowid"] = int(data.get("last_event_rowid") or 0)
        if data.get("bootstrapped_at"):
            st["bootstrapped_at"] = data["bootstrapped_at"]
        st["pending_offline_seed"] = True
        return st
    return None


def load_state(path: str) -> tuple[dict[str, Any] | None, str | None]:
    """Return (state, error). None state + error => bootstrap gerekli."""
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        if not isinstance(raw, dict):
            return None, "state:not-object"
        ver = raw.get("version")
        if ver == STATE_VERSION:
            st = _empty_state()
            for stream in STREAMS:
                cur = (raw.get("streams") or {}).get(stream) or {}
                st["streams"][stream]["last_rowid"] = int(cur.get("last_rowid") or 0)
            if raw.get("bootstrapped_at"):
                st["bootstrapped_at"] = raw["bootstrapped_at"]
            if raw.get("pending_offline_seed"):
                st["pending_offline_seed"] = True
            return st, None
        if ver == 2:
            migrated = _migrate_state(raw)
            if migrated:
                save_state(path, migrated)
                return migrated, None
        return None, "state:bad-version"
    except FileNotFoundError:
        return None, "state:missing"
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"state:corrupt:{exc}"


def save_state(path: str, state: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def max_event_rowid(con: sqlite3.Connection, event_type: str | None = None) -> int:
    if event_type:
        row = con.execute(
            "SELECT COALESCE(MAX(rowid), 0) FROM Events WHERE eveEventType=?",
            (event_type,),
        ).fetchone()
    else:
        row = con.execute("SELECT COALESCE(MAX(rowid), 0) FROM Events").fetchone()
    return int(row[0] or 0)


def bootstrap_state(db_path: str, state_path: str) -> None:
    con = _open_db(db_path)
    state = _empty_state()
    for stream, ev_type in STREAMS.items():
        state["streams"][stream]["last_rowid"] = max_event_rowid(con, ev_type)
    state["bootstrapped_at"] = datetime.now(timezone.utc).isoformat()
    con.close()
    save_state(state_path, state)


def commit_rowid(state_path: str, stream: str, max_rowid: int) -> None:
    if stream not in STREAMS:
        raise ValueError(f"unknown stream: {stream}")
    state, err = load_state(state_path)
    if state is None:
        raise RuntimeError(f"commit without state: {err}")
    cur = int(state["streams"][stream].get("last_rowid") or 0)
    if max_rowid > cur:
        state["streams"][stream]["last_rowid"] = max_rowid
        save_state(state_path, state)


def online_devices(db_path: str, *, recency_sec: int = 900) -> list[dict[str, str]]:
    """Homepage/Grafana kim-evde — Telegram yok."""
    con = _open_db(db_path)
    try:
        cols = {row[1] for row in con.execute("PRAGMA table_info(Devices)")}
        where = "COALESCE(devIsArchived, 0)=0"
        args: list[Any] = []
        if "devPresent" in cols:
            where += " AND COALESCE(devPresent, 0)=1"
        elif "devLastConnection" in cols:
            where += " AND COALESCE(devLastConnection, 0) >= ?"
            args.append(time.time() - recency_sec)
        sql = f"""
            SELECT devMac, devName, devVendor, devType, devLastIP
            FROM Devices
            WHERE {where}
            ORDER BY devName COLLATE NOCASE
        """
        rows = con.execute(sql, args).fetchall()
        out: list[dict[str, str]] = []
        for mac, name, vendor, dtype, ip in rows:
            mac_s = (mac or "").strip().lower()
            if _is_noise_mac(mac_s):
                continue
            display = suggest_display_name(name, vendor, dtype, ip, mac_s)
            out.append(
                {
                    "mac": mac_s,
                    "name": display,
                    "ip": (ip or "").strip(),
                    "vendor": (vendor or "").strip() or "?",
                }
            )
        return out
    finally:
        con.close()


def fetch_device(con: sqlite3.Connection, mac: str) -> dict[str, str] | None:
    row = con.execute(
        """
        SELECT devName, devVendor, devType, devLastIP, devSourcePlugin,
               devFirstConnection, devLastConnection, devFQDN
        FROM Devices
        WHERE devMac=? AND COALESCE(devIsArchived, 0)=0
        """,
        (mac,),
    ).fetchone()
    if not row:
        return None
    name, vendor, dtype, ip, source, first_ts, last_ts, fqdn = row
    display = suggest_display_name(name, vendor, dtype, ip, mac)
    return {
        "name": display,
        "vendor": (vendor or "").strip() or "?",
        "type": (dtype or "").strip() or "?",
        "ip": (ip or "").strip() or "?",
        "source": (source or "").strip() or "?",
        "first_seen": _ts_local(first_ts),
        "last_seen": _ts_local(last_ts),
        "fqdn": (fqdn or "").strip(),
    }


def device_from_event(
    con: sqlite3.Connection,
    rowid: int,
    mac: str,
    ip: str,
    event_ts: int | float | str | None,
    event_info: str | None,
) -> dict[str, Any] | None:
    mac = (mac or "").strip().lower()
    if not mac or mac in SKIP_MACS:
        return None
    ip = (ip or "").strip()
    if ip in ("", "0.0.0.0"):
        ip = "?"

    dev = fetch_device(con, mac)
    if dev:
        name = dev["name"]
        vendor = dev["vendor"]
        dtype = dev["type"]
        source = dev["source"]
        first_seen = dev["first_seen"]
        last_seen = dev.get("last_seen") or "?"
        if last_seen == "?" and event_ts is not None:
            last_seen = _ts_local(event_ts)
        fqdn = dev.get("fqdn") or ""
    else:
        info = (event_info or "").strip()
        vendor = info if info and info not in ("(Unknown)",) else "?"
        dtype = "?"
        source = "?"
        first_seen = _ts_local(event_ts)
        last_seen = first_seen
        name = suggest_display_name(None, vendor, dtype, ip, mac)
        fqdn = ""

    return {
        "mac": mac,
        "ip": ip,
        "name": name,
        "vendor": vendor,
        "type": dtype,
        "source": source,
        "first_seen": first_seen,
        "last_seen": last_seen,
        "fqdn": fqdn,
        "event_rowid": rowid,
        "event_info": (event_info or "").strip(),
    }


def repair_stream_cursors(state_path: str, db_path: str) -> None:
    """v2 migrate sonrası offline geçmiş flood — tek seferlik cursor seed."""
    state, err = load_state(state_path)
    if state is None or not state.pop("pending_offline_seed", False):
        return
    con = _open_db(db_path)
    state["streams"]["offline"]["last_rowid"] = max_event_rowid(con, "Disconnected")
    con.close()
    save_state(state_path, state)


def poll_stream(
    db_path: str,
    state_path: str,
    stream: str,
) -> tuple[list[dict[str, Any]], int, str | None]:
    if stream not in STREAMS:
        raise ValueError(stream)
    event_type = STREAMS[stream]

    state, err = load_state(state_path)
    if state is None:
        return [], 0, err

    con = _open_db(db_path)
    last = int(state["streams"][stream].get("last_rowid") or 0)
    rows = con.execute(
        """
        SELECT rowid, eveMac, eveIp, eveDateTime, eveAdditionalInfo
        FROM Events
        WHERE eveEventType=? AND rowid>?
        ORDER BY rowid ASC
        """,
        (event_type, last),
    ).fetchall()

    devices: list[dict[str, Any]] = []
    by_mac: dict[str, dict[str, Any]] = {}
    max_rowid = last
    for rowid, mac, ip, event_ts, info in rows:
        max_rowid = max(max_rowid, int(rowid))
        if stream == "new_device" and _is_noise_mac(mac, new_device=True):
            continue
        dev = device_from_event(con, int(rowid), mac, ip, event_ts, info)
        if dev:
            if stream == "offline":
                by_mac[dev["mac"]] = dev
            else:
                by_mac[dev["mac"]] = dev

    if stream == "offline" and by_mac:
        devices = sorted(by_mac.values(), key=lambda d: int(d["event_rowid"]))
    elif stream == "new_device" and by_mac:
        devices = sorted(by_mac.values(), key=lambda d: int(d["event_rowid"]))

    con.close()
    return devices, max_rowid, None


def _devices_panel_url() -> str:
    remote_dir = os.environ.get("REMOTE_DIR", os.path.expanduser("~/pi-gateway"))
    panels = os.path.join(remote_dir, "scripts/lib/telegram-panels.py")
    if not os.path.isfile(panels):
        return ""
    try:
        return subprocess.check_output(
            [sys.executable, panels, "panel_url", "devices"],
            text=True,
            timeout=5,
            stderr=subprocess.DEVNULL,
            env=os.environ,
        ).strip()
    except (subprocess.SubprocessError, OSError, ValueError):
        return ""


def _plain_header() -> list[str]:
    return [
        "📋 Ağ Bildirimi",
        datetime.now().strftime("%d.%m.%Y %H:%M"),
        "",
    ]


def _plain_footer(*, offline: bool) -> list[str]:
    panel = _devices_panel_url()
    blocks: list[str] = ["", "Ne yapmalı?"]
    if offline:
        if panel:
            blocks.append(f"• Durum: {panel}")
        blocks.append("• Beklenen cihazsa sorun yok; tanımıyorsan incele.")
    else:
        blocks.append("• Tanımıyorsan ağ cihazları panelinden incele.")
        if panel:
            blocks.append(f"• Durum: {panel}")
    return blocks


def format_new_plain(devices: list[dict[str, Any]]) -> str:
    if not devices:
        return ""
    n = len(devices)
    headline = (
        "Ev ağında yeni cihaz görüldü."
        if n == 1
        else f"Ev ağında {n} yeni cihaz görüldü."
    )
    blocks: list[str] = _plain_header() + [headline, ""]
    for i, d in enumerate(devices, 1):
        prefix = f"{i}. " if n > 1 else ""
        lines = [
            f"{prefix}Cihaz: {d['name']}",
            f"IP: {d['ip']}",
            f"MAC: `{d['mac']}`",
        ]
        if d.get("type") and d["type"] != "?":
            lines.append(f"Tür: {d['type']}")
        if d.get("vendor") and d["vendor"] not in ("?", "(Unknown)"):
            lines.append(f"Üretici: {d['vendor']}")
        if d.get("source") and d["source"] != "?":
            lines.append(f"Kaynak: {d['source']}")
        lines.append(f"İlk görülme: {d['first_seen']}")
        if d.get("fqdn"):
            lines.append(f"FQDN: {d['fqdn']}")
        blocks.append("\n".join(lines))
        blocks.append("")
    blocks.extend(_plain_footer(offline=False))
    return "\n".join(blocks).rstrip()


def format_offline_plain(devices: list[dict[str, Any]]) -> str:
    if not devices:
        return ""
    n = len(devices)
    headline = (
        "Ev ağında bir cihaz yanıt vermiyor."
        if n == 1
        else f"Ev ağında {n} cihaz yanıt vermiyor."
    )
    blocks: list[str] = _plain_header() + [headline, ""]
    for i, d in enumerate(devices, 1):
        prefix = f"{i}. " if n > 1 else ""
        lines = [
            f"{prefix}{d['name']}",
            f"Son IP: {d['ip']}",
            f"MAC: `{d['mac']}`",
        ]
        last_seen = d.get("last_seen") or "?"
        if last_seen != "?":
            lines.append(f"Son görülme: {last_seen}")
        blocks.append("\n".join(lines))
        blocks.append("")
    blocks.extend(_plain_footer(offline=True))
    return "\n".join(blocks).rstrip()


def format_html_detail(devices: list[dict[str, Any]], *, offline: bool = False) -> str:
    if not devices:
        return ""
    parts: list[str] = []
    for i, d in enumerate(devices, 1):
        title = d["name"] if len(devices) == 1 else f"{i}. {d['name']}"
        chunk = [
            f"<b>{_esc(title)}</b>",
            f"IP: <code>{_esc(d['ip'])}</code>",
            f"MAC: <code>{_esc(d['mac'])}</code>",
        ]
        if offline:
            last_seen = d.get("last_seen") or "?"
            if last_seen != "?":
                chunk.append(f"Son görülme: {_esc(last_seen)}")
        else:
            meta: list[str] = []
            if d.get("type") and d["type"] != "?":
                meta.append(_esc(d["type"]))
            if d.get("vendor") and d["vendor"] not in ("?", "(Unknown)"):
                meta.append(_esc(d["vendor"]))
            if meta:
                chunk.append("Tür: " + " · ".join(meta))
            if d.get("source") and d["source"] != "?":
                chunk.append(f"Kaynak: {_esc(d['source'])}")
            chunk.append(f"İlk görülme: {_esc(d['first_seen'])}")
            if d.get("fqdn"):
                chunk.append(f"FQDN: {_esc(d['fqdn'])}")
        parts.append("\n".join(chunk))
    return "\n\n".join(parts)


def _esc(text: str) -> str:
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def build_envelope(
    db_path: str,
    state_path: str,
    stream: str,
) -> dict[str, Any]:
    repair_stream_cursors(state_path, db_path)
    devices, max_rowid, err = poll_stream(db_path, state_path, stream)
    offline = stream == "offline"
    plain_fn = format_offline_plain if offline else format_new_plain
    plain = plain_fn(devices) if devices else ""
    return {
        "stream": stream,
        "count": len(devices),
        "max_rowid": max_rowid,
        "devices": devices,
        "plain": plain,
        "html_detail": format_html_detail(devices, offline=offline) if devices else "",
        "state_error": err,
    }


def _self_check() -> None:
    import tempfile

    with tempfile.TemporaryDirectory() as td:
        db = os.path.join(td, "app.db")
        state = os.path.join(td, "state.json")
        con = sqlite3.connect(db)
        con.executescript(
            """
            CREATE TABLE Devices (
              devMac TEXT PRIMARY KEY, devName TEXT, devVendor TEXT, devType TEXT,
              devLastIP TEXT, devSourcePlugin TEXT, devFirstConnection REAL,
              devLastConnection REAL, devFQDN TEXT, devIsArchived INTEGER
            );
            CREATE TABLE Events (
              eveMac TEXT, eveIp TEXT, eveDateTime REAL, eveEventType TEXT,
              eveAdditionalInfo TEXT
            );
            """
        )
        now = time.time()
        con.execute(
            "INSERT INTO Devices VALUES (?,?,?,?,?,?,?,?,?,0)",
            ("aa:bb:cc:dd:ee:01", "?", "Apple, Inc.", "Phone", "192.168.1.50",
             "ARPSCAN", now - 60, now, None),
        )
        con.execute(
            "INSERT INTO Events VALUES (?,?,?,?,?)",
            ("internet", "0.0.0.0", now, "New Device", "(Unknown)"),
        )
        con.execute(
            "INSERT INTO Events VALUES (?,?,?,?,?)",
            ("aa:bb:cc:dd:ee:01", "192.168.1.50", now, "New Device", "(Unknown)"),
        )
        con.commit()
        con.close()

        bootstrap_state(db, state)
        env = build_envelope(db, state, "new_device")
        assert env["count"] == 0, "bootstrap sonrası bildirim olmamalı"

        con = sqlite3.connect(db)
        con.execute(
            "INSERT INTO Events VALUES (?,?,?,?,?)",
            ("bb:cc:dd:ee:ff:02", "192.168.1.51", now + 1, "New Device",
             "(Unknown: locally administered)"),
        )
        con.execute(
            "INSERT INTO Events VALUES (?,?,?,?,?)",
            ("aa:bb:cc:dd:ee:01", "192.168.1.50", now + 2, "Disconnected", ""),
        )
        con.commit()
        con.close()

        env = build_envelope(db, state, "new_device")
        assert env["count"] == 0, "gizlilik MAC bildirilmemeli"
        con = sqlite3.connect(db)
        con.execute(
            "INSERT INTO Events VALUES (?,?,?,?,?)",
            ("dd:ee:ff:00:11:04", "192.168.1.53", now + 2, "New Device", "TP-Link"),
        )
        con.commit()
        con.close()
        env = build_envelope(db, state, "new_device")
        assert env["count"] == 1, env
        assert "`dd:ee:ff:00:11:04`" in env["plain"], env["plain"]
        commit_rowid(state, "new_device", env["max_rowid"])
        env2 = build_envelope(db, state, "new_device")
        assert env2["count"] == 0

        off = build_envelope(db, state, "offline")
        assert off["count"] == 1, off
        assert "yanıt vermiyor" in off["plain"].lower() or "çevrimdışı" in off["plain"].lower()

        bad = os.path.join(td, "bad.json")
        with open(bad, "w", encoding="utf-8") as fh:
            fh.write('{"version": 99}')
        st, err = load_state(bad)
        assert st is None and err

        home = online_devices(db)
        assert any(d["mac"] == "aa:bb:cc:dd:ee:01" for d in home), home

    print("[netalert-devices] self-check OK")


def main() -> int:
    ap = argparse.ArgumentParser(description="NetAlertX Events poll")
    ap.add_argument("--db", default="")
    ap.add_argument("--state", default="")
    ap.add_argument("--stream", choices=tuple(STREAMS), default="new_device")
    ap.add_argument("--bootstrap", action="store_true")
    ap.add_argument("--commit-rowid", type=int, default=0, metavar="N")
    ap.add_argument(
        "--emit",
        choices=("envelope", "plain"),
        default="envelope",
    )
    ap.add_argument("--self-check", action="store_true")
    ap.add_argument("--online-json", action="store_true")
    args = ap.parse_args()

    if args.self_check:
        _self_check()
        return 0

    if args.online_json:
        if not args.db:
            ap.error("--db required with --online-json")
        json.dump(online_devices(args.db), sys.stdout, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    if not args.db or not args.state:
        ap.error("--db and --state required unless --self-check")

    if args.bootstrap:
        bootstrap_state(args.db, args.state)
        return 0

    if args.commit_rowid:
        commit_rowid(args.state, args.stream, args.commit_rowid)
        return 0

    payload = build_envelope(args.db, args.state, args.stream)
    if payload.get("state_error"):
        print(f"[netalert-devices] ERROR {payload['state_error']}", file=sys.stderr)
        return 2

    if args.emit == "plain":
        if payload["plain"]:
            sys.stdout.write(payload["plain"])
            sys.stdout.write("\n")
        return 0

    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
