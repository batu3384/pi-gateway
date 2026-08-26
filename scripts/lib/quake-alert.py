#!/usr/bin/env python3
"""AFAD deprem — çift eşik, artçı + saat tavanı + gece sıkı. Telegram P1."""
from __future__ import annotations

import json
import math
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

HOME_LAT = float(os.environ.get("QUAKE_HOME_LAT", "41.0082"))
HOME_LON = float(os.environ.get("QUAKE_HOME_LON", "28.9784"))
LOCAL_KM = float(os.environ.get("QUAKE_LOCAL_KM", "280"))
LOCAL_MAG = float(os.environ.get("QUAKE_LOCAL_MAG", "3.5"))
NATIONAL_MAG = float(os.environ.get("QUAKE_NATIONAL_MAG", "5.0"))
AFTERSHOCK_KM = float(os.environ.get("QUAKE_AFTERSHOCK_KM", "50"))
AFTERSHOCK_H = float(os.environ.get("QUAKE_AFTERSHOCK_H", "6"))
HOUR_CAP = int(os.environ.get("QUAKE_HOUR_CAP", "3"))
HOUR_CAP_BYPASS = float(os.environ.get("QUAKE_HOUR_CAP_BYPASS_MAG", "5.5"))
NIGHT_LOCAL_MAG = float(os.environ.get("QUAKE_NIGHT_LOCAL_MAG", "4.0"))
STATE_PATH = Path(os.environ.get("QUAKE_STATE", "/var/lib/pi-gateway/quake-state.json"))
AFAD = "https://deprem.afad.gov.tr/apiv2/event/filter"


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(min(a, 1.0)))


def is_night(now: datetime | None = None) -> bool:
    now = now or datetime.now().astimezone()
    return now.hour < 7  # 00:00–06:59


def _mag(ev: dict[str, Any]) -> float:
    for k in ("magnitude", "mag", "ml"):
        try:
            return float(ev.get(k))
        except (TypeError, ValueError):
            continue
    return 0.0


def _id(ev: dict[str, Any]) -> str:
    for k in ("eventID", "eventId", "id"):
        v = ev.get(k)
        if v is not None and str(v).strip():
            return str(v).strip()
    return ""


def _latlon(ev: dict[str, Any]) -> tuple[float, float] | None:
    try:
        lat = float(ev.get("latitude") if ev.get("latitude") is not None else ev.get("lat"))
        lon = float(ev.get("longitude") if ev.get("longitude") is not None else ev.get("lon"))
        return lat, lon
    except (TypeError, ValueError):
        return None


def qualifies(ev: dict[str, Any], *, night: bool = False) -> bool:
    mag = _mag(ev)
    loc = _latlon(ev)
    if loc is None:
        return mag >= NATIONAL_MAG
    dist = haversine_km(HOME_LAT, HOME_LON, loc[0], loc[1])
    local_cut = NIGHT_LOCAL_MAG if night else LOCAL_MAG
    if dist <= LOCAL_KM and mag >= local_cut:
        return True
    return mag >= NATIONAL_MAG


def load_state(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def is_aftershock(ev: dict[str, Any], last: dict[str, Any] | None, now_ts: float) -> bool:
    if not last:
        return False
    mag = _mag(ev)
    if mag >= 5.0:
        return False
    try:
        last_mag = float(last.get("mag") or 0)
        last_ts = float(last.get("ts") or 0)
        last_lat = float(last.get("lat"))
        last_lon = float(last.get("lon"))
    except (TypeError, ValueError):
        return False
    if mag >= last_mag + 0.5:
        return False
    if now_ts - last_ts > AFTERSHOCK_H * 3600:
        return False
    loc = _latlon(ev)
    if loc is None:
        return False
    return haversine_km(last_lat, last_lon, loc[0], loc[1]) <= AFTERSHOCK_KM


def hour_blocked(sent_ts: list[float], now_ts: float, mag: float) -> bool:
    if mag >= HOUR_CAP_BYPASS:
        return False
    recent = [t for t in sent_ts if now_ts - t < 3600]
    return len(recent) >= HOUR_CAP


def format_msg(ev: dict[str, Any]) -> str:
    mag = _mag(ev)
    loc = _latlon(ev)
    place = str(ev.get("location") or ev.get("place") or "konum yok")
    when = str(ev.get("date") or ev.get("eventDate") or "")
    dist = ""
    if loc:
        km = haversine_km(HOME_LAT, HOME_LON, loc[0], loc[1])
        dist = f" · ev {km:.0f} km"
    return (
        f"M{mag:.1f} {place}{dist}\n"
        f"{when}\n"
        "Kaynak: AFAD"
    )


def fetch_events() -> list[dict[str, Any]]:
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=6)
    url = (
        f"{AFAD}?start={start.strftime('%Y-%m-%d')}&end={end.strftime('%Y-%m-%d')}"
        f"&minMag={min(LOCAL_MAG, 3.0)}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "pi-gateway-quake/1"})
    with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
        data = json.loads(resp.read().decode("utf-8"))
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for k in ("data", "result", "events"):
            if isinstance(data.get(k), list):
                return data[k]
    return []


def due_events(events: list[dict[str, Any]], state: dict[str, Any], now_ts: float) -> list[dict[str, Any]]:
    seen = set(state.get("seen") or [])
    sent_ts = [float(x) for x in (state.get("sent_ts") or [])]
    last = state.get("last") if isinstance(state.get("last"), dict) else None
    night = is_night(datetime.fromtimestamp(now_ts).astimezone())
    due: list[dict[str, Any]] = []
    for ev in events:
        eid = _id(ev)
        if not eid or eid in seen:
            continue
        if not qualifies(ev, night=night):
            continue
        if is_aftershock(ev, last, now_ts):
            continue
        if hour_blocked(sent_ts, now_ts, _mag(ev)):
            continue
        due.append(ev)
        seen.add(eid)
        sent_ts.append(now_ts)
        loc = _latlon(ev) or (0.0, 0.0)
        last = {"mag": _mag(ev), "ts": now_ts, "lat": loc[0], "lon": loc[1]}
    state["seen"] = list(seen)[-400:]
    state["sent_ts"] = [t for t in sent_ts if now_ts - t < 86400][-50:]
    state["last"] = last
    return due


def self_check() -> None:
    ist = haversine_km(41.0, 29.0, 40.7, 29.4)
    assert 40 < ist < 80, ist
    izmir = {"magnitude": 3.6, "latitude": 38.4, "longitude": 27.1, "eventID": "a"}
    marmara = {"magnitude": 3.6, "latitude": 40.8, "longitude": 28.5, "eventID": "b"}
    big = {"magnitude": 5.1, "latitude": 38.4, "longitude": 27.1, "eventID": "c"}
    assert qualifies(marmara, night=False)
    assert not qualifies(izmir, night=False)
    assert qualifies(big, night=False)
    assert not qualifies(marmara, night=True)
    night_ok = {"magnitude": 4.1, "latitude": 40.8, "longitude": 28.5, "eventID": "d"}
    assert qualifies(night_ok, night=True)
    last = {"mag": 3.8, "ts": time.time() - 3600, "lat": 40.8, "lon": 28.5}
    artci = {"magnitude": 3.6, "latitude": 40.82, "longitude": 28.52, "eventID": "e"}
    assert is_aftershock(artci, last, time.time())
    assert hour_blocked([time.time() - 10] * 3, time.time(), 3.6)
    assert not hour_blocked([time.time() - 10] * 3, time.time(), 5.6)
    print("[quake-alert] self-check OK")


def main() -> int:
    import sys

    if "--self-check" in sys.argv:
        self_check()
        return 0
    try:
        events = fetch_events()
    except (OSError, TimeoutError, json.JSONDecodeError, urllib.error.URLError, ValueError) as exc:
        print(f"[quake] fetch fail: {exc}", file=sys.stderr)
        return 0
    state = load_state(STATE_PATH)
    due = due_events(events, state, time.time())
    save_state(STATE_PATH, state)
    for ev in due:
        print(format_msg(ev))
        print("---")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
