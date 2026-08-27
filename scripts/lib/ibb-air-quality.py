#!/usr/bin/env python3
"""İBB açık veri HKI → Prometheus textfile + stdout satırı (Telegram sarmalayıcı)."""
from __future__ import annotations

import json
import math
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

STATIONS_URL = (
    "https://api.ibb.gov.tr/havakalitesi/OpenDataPortalHandler/GetAQIStations"
)
BY_ID_URL = (
    "https://api.ibb.gov.tr/havakalitesi/OpenDataPortalHandler/GetAQIByStationId"
)
UA = "pi-gateway-ibb/1"
IST = ZoneInfo("Europe/Istanbul")
SKIP_NAMES = {"mobil"}


def esc(label: str) -> str:
    return label.replace("\\", "\\\\").replace("\n", " ").replace('"', '\\"')


def parse_point(loc: str) -> tuple[float, float] | None:
    m = re.search(r"POINT\s*\(\s*([+-]?\d+(?:\.\d+)?)\s+([+-]?\d+(?:\.\d+)?)\s*\)", loc or "")
    if not m:
        return None
    lon, lat = float(m.group(1)), float(m.group(2))
    return lat, lon


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def http_json(url: str, timeout: int) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8", errors="replace")
    return json.loads(raw)


def pick_station(
    stations: list[Any],
    station_id: str,
    home_lat: float,
    home_lon: float,
) -> dict[str, Any] | None:
    rows = [s for s in stations if isinstance(s, dict)]
    if station_id:
        for s in rows:
            if str(s.get("Id") or "") == station_id:
                return s
        return None
    best: dict[str, Any] | None = None
    best_d = 1e9
    for s in rows:
        name = str(s.get("Name") or "").strip().lower()
        if name in SKIP_NAMES:
            continue
        pt = parse_point(str(s.get("Location") or ""))
        if pt is None:
            continue
        d = haversine_km(home_lat, home_lon, pt[0], pt[1])
        if d < best_d:
            best_d = d
            best = s
    return best


def latest_sample(rows: list[Any]) -> dict[str, Any] | None:
    last: dict[str, Any] | None = None
    last_ts = ""
    for item in rows:
        if not isinstance(item, dict):
            continue
        aqi = item.get("AQI")
        if not isinstance(aqi, dict):
            continue
        idx = aqi.get("AQIIndex")
        if idx is None:
            continue
        ts = str(item.get("ReadTime") or "")
        if ts >= last_ts:
            last_ts = ts
            last = item
    return last


def _num(v: Any) -> float:
    if v is None:
        return -1.0
    try:
        return float(v)
    except (TypeError, ValueError):
        return -1.0


def render_prom(up: int, station: dict[str, Any], sample: dict[str, Any] | None) -> str:
    name = esc(str(station.get("Name") or "unknown"))
    sid = esc(str(station.get("Id") or ""))
    aqi: dict[str, Any] = {}
    conc: dict[str, Any] = {}
    if sample:
        aqi = sample.get("AQI") if isinstance(sample.get("AQI"), dict) else {}
        conc = sample.get("Concentration") if isinstance(sample.get("Concentration"), dict) else {}
    hki = _num(aqi.get("AQIIndex"))
    labels = f'station="{name}",id="{sid}"'
    lines = [
        "# HELP pi_gateway_ibb_up 1 when İBB AQI scrape succeeded",
        "# TYPE pi_gateway_ibb_up gauge",
        f"pi_gateway_ibb_up {int(up)}",
        "# HELP pi_gateway_ibb_hki Hourly air quality index (HKI / AQIIndex)",
        "# TYPE pi_gateway_ibb_hki gauge",
        f"pi_gateway_ibb_hki{{{labels}}} {hki:.1f}",
        "# HELP pi_gateway_ibb_pm10 PM10 concentration ug/m3 (-1 missing)",
        "# TYPE pi_gateway_ibb_pm10 gauge",
        f"pi_gateway_ibb_pm10{{{labels}}} {_num(conc.get('PM10')):.1f}",
        "# HELP pi_gateway_ibb_no2 NO2 concentration ug/m3 (-1 missing)",
        "# TYPE pi_gateway_ibb_no2 gauge",
        f"pi_gateway_ibb_no2{{{labels}}} {_num(conc.get('NO2')):.1f}",
        "# HELP pi_gateway_ibb_so2 SO2 concentration ug/m3 (-1 missing)",
        "# TYPE pi_gateway_ibb_so2 gauge",
        f"pi_gateway_ibb_so2{{{labels}}} {_num(conc.get('SO2')):.1f}",
        "# HELP pi_gateway_ibb_o3 O3 concentration ug/m3 (-1 missing)",
        "# TYPE pi_gateway_ibb_o3 gauge",
        f"pi_gateway_ibb_o3{{{labels}}} {_num(conc.get('O3')):.1f}",
    ]
    return "\n".join(lines) + "\n"


def write_atomic(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def self_check() -> None:
    stations = [
        {
            "Id": "cb4cd1c2-b55b-484f-ac7a-505369405d00",
            "Name": "Aksaray",
            "Location": "POINT (28.953951591074674 41.014416544618882)",
        },
        {
            "Id": "skip",
            "Name": "Mobil",
            "Location": "POINT (28.94 41.05)",
        },
    ]
    picked = pick_station(stations, "", 41.0082, 28.9784)
    assert picked is not None and picked["Name"] == "Aksaray"
    rows = [
        {"ReadTime": "2026-08-27T10:00:00", "AQI": None},
        {
            "ReadTime": "2026-08-27T14:00:00",
            "Concentration": {"PM10": 30.1, "NO2": 88.2, "SO2": 99.6, "O3": 32.3},
            "AQI": {
                "AQIIndex": 53.0,
                "ContaminantParameter": "SO2",
                "State": "orta",
            },
        },
        {
            "ReadTime": "2026-08-27T12:00:00",
            "Concentration": {"PM10": 1},
            "AQI": {"AQIIndex": 10.0, "ContaminantParameter": "PM10"},
        },
    ]
    sample = latest_sample(rows)
    assert sample is not None and sample["ReadTime"].startswith("2026-08-27T14")
    text = render_prom(1, picked, sample)
    assert 'pi_gateway_ibb_hki{station="Aksaray"' in text
    assert "53.0" in text
    assert "pi_gateway_ibb_up 0" in render_prom(0, {"Name": "x", "Id": "y"}, None)
    d = haversine_km(41.0, 29.0, 41.0, 29.0)
    assert d < 0.01
    print("[ibb-air-quality] self-check OK")


def main() -> int:
    if "--self-check" in sys.argv:
        self_check()
        return 0
    out = os.environ.get("PI_GATEWAY_METRICS_DIR", "/var/lib/pi-gateway/metrics")
    dest = os.environ.get("PI_GATEWAY_IBB_PROM") or os.path.join(out, "pi_gateway_ibb.prom")
    timeout = int(os.environ.get("IBB_HTTP_TIMEOUT_SEC", "20"))
    warn = float(os.environ.get("IBB_HKI_WARN", "51"))
    station_id = (os.environ.get("IBB_AQI_STATION_ID") or "").strip()
    try:
        lat = float(os.environ.get("IBB_HOME_LAT") or os.environ.get("QUAKE_HOME_LAT") or "41.0082")
        lon = float(os.environ.get("IBB_HOME_LON") or os.environ.get("QUAKE_HOME_LON") or "28.9784")
    except ValueError:
        lat, lon = 41.0082, 28.9784
    empty_st = {"Name": "none", "Id": ""}
    try:
        stations = http_json(STATIONS_URL, timeout)
        if not isinstance(stations, list):
            raise ValueError("stations not list")
        st = pick_station(stations, station_id, lat, lon)
        if st is None:
            write_atomic(dest, render_prom(0, empty_st, None))
            print("status=fail reason=no-station")
            return 0
        now = datetime.now(IST)
        start = (now - timedelta(hours=30)).strftime("%d.%m.%Y %H:%M:%S")
        end = (now + timedelta(hours=2)).strftime("%d.%m.%Y %H:%M:%S")
        sid = str(st.get("Id") or "")
        q = (
            f"{BY_ID_URL}?StationId={urllib.parse.quote(sid)}"
            f"&StartDate={urllib.parse.quote(start)}"
            f"&EndDate={urllib.parse.quote(end)}"
        )
        rows = http_json(q, timeout)
        if not isinstance(rows, list):
            raise ValueError("samples not list")
        sample = latest_sample(rows)
        write_atomic(dest, render_prom(1 if sample else 0, st, sample))
        if sample is None:
            print(f"status=fail reason=no-sample station={st.get('Name')}")
            return 0
        aqi = sample.get("AQI") if isinstance(sample.get("AQI"), dict) else {}
        hki = _num(aqi.get("AQIIndex"))
        band = "warn" if hki >= warn else "ok"
        poll = str(aqi.get("ContaminantParameter") or "")
        state = str(aqi.get("State") or "")[:180]
        read = str(sample.get("ReadTime") or "")
        print(
            f"status={band} station={st.get('Name')} hki={hki:.0f} "
            f"pollutant={poll} read={read} state={state}"
        )
        return 0
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError) as exc:
        try:
            write_atomic(dest, render_prom(0, empty_st, None))
        except OSError:
            pass
        print(f"status=fail reason={type(exc).__name__}")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
