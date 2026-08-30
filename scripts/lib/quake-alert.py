#!/usr/bin/env python3
"""Deprem Telegram — AFAD + Kandilli poll (yayın sonrası). EEW/saniye değil.

Hermes yok: systemd timer → bu script → notify.sh Bot API.
Gecikme ≈ kaynak yayın + poll (varsayılan 10s).
"""
from __future__ import annotations

import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
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
# Yalnız son N sn içindeki olaylar Telegram’a (eski liste spam engeli)
MAX_EVENT_AGE_SEC = int(os.environ.get("QUAKE_MAX_EVENT_AGE_SEC", "1200"))  # 20 dk
# Poll 10s → HTTP kısa tut; AFAD+Kandilli paralel
HTTP_TIMEOUT_SEC = float(os.environ.get("QUAKE_HTTP_TIMEOUT_SEC", "5"))
FP_BUCKET_SEC = int(os.environ.get("QUAKE_FP_BUCKET_SEC", "180"))  # 3 dk
STATE_PATH = Path(os.environ.get("QUAKE_STATE", "/var/lib/pi-gateway/quake-state.json"))
PARTIAL_WARN_PATH = STATE_PATH.with_name("quake-partial-warn.json")
PARTIAL_WARN_MIN_SEC = int(os.environ.get("QUAKE_PARTIAL_WARN_MIN_SEC", "900"))
AFAD = "https://deprem.afad.gov.tr/apiv2/event/filter"
KANDILLI = os.environ.get(
    "QUAKE_KANDILLI_URL",
    "http://www.koeri.boun.edu.tr/scripts/lst0.asp",
)


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


def _latlon(ev: dict[str, Any]) -> tuple[float, float] | None:
    try:
        lat = float(ev.get("latitude") if ev.get("latitude") is not None else ev.get("lat"))
        lon = float(ev.get("longitude") if ev.get("longitude") is not None else ev.get("lon"))
        return lat, lon
    except (TypeError, ValueError):
        return None


def _parse_event_time(raw: str) -> datetime | None:
    raw = raw.strip()
    if not raw:
        return None
    candidates = [
        raw[:19],
        raw[:19].replace("T", " "),
    ]
    for s in candidates:
        for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
            try:
                dt = datetime.strptime(s, fmt)
                return dt.replace(tzinfo=timezone(timedelta(hours=3)))
            except ValueError:
                continue
    return None


def _event_ts(ev: dict[str, Any]) -> float | None:
    dt = _parse_event_time(str(ev.get("date") or ev.get("eventDate") or ""))
    return dt.timestamp() if dt else None


def fingerprint(ev: dict[str, Any]) -> str:
    """Kaynaklar arası tek olay — yaklaşık zaman + konum + büyüklük."""
    loc = _latlon(ev)
    mag = round(_mag(ev), 1)
    ts = _event_ts(ev)
    if loc is None:
        return f"fp:nomap:{mag}:{ev.get('eventID') or ev.get('date') or ''}"
    bucket = int((ts or 0) // FP_BUCKET_SEC)  # AFAD/Kandilli saat farkı
    return f"fp:{bucket}:{loc[0]:.2f}:{loc[1]:.2f}:{mag:.1f}"


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
    src = str(ev.get("source") or "AFAD")
    dist = ""
    if loc:
        km = haversine_km(HOME_LAT, HOME_LON, loc[0], loc[1])
        dist = f" · evden ~{km:.0f} km"
    return (
        f"Büyüklük M{mag:.1f} — {place}{dist}\n"
        f"Zaman: {when}\n"
        f"Kaynak: {src}"
    )


def _http_get(url: str, timeout: float | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "pi-gateway-quake/2"})
    with urllib.request.urlopen(req, timeout=timeout or HTTP_TIMEOUT_SEC) as resp:  # noqa: S310
        return resp.read()


def fetch_afad() -> list[dict[str, Any]]:
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=6)
    url = (
        f"{AFAD}?start={start.strftime('%Y-%m-%d')}&end={end.strftime('%Y-%m-%d')}"
        f"&minMag={min(LOCAL_MAG, 3.0)}"
    )
    data = json.loads(_http_get(url).decode("utf-8"))
    rows: list[Any]
    if isinstance(data, list):
        rows = data
    elif isinstance(data, dict):
        rows = next(
            (data[k] for k in ("data", "result", "events") if isinstance(data.get(k), list)),
            [],
        )
    else:
        rows = []
    out: list[dict[str, Any]] = []
    for ev in rows:
        if not isinstance(ev, dict):
            continue
        item = dict(ev)
        item["source"] = "AFAD"
        if not item.get("eventID") and item.get("eventId"):
            item["eventID"] = item["eventId"]
        out.append(item)
    return out


def parse_kandilli_line(line: str) -> dict[str, Any] | None:
    """Kandilli lst0 sabit sütun: tarih saat lat lon derinlik MD ML Mw yer …"""
    parts = line.split()
    if len(parts) < 9:
        return None
    try:
        when = f"{parts[0]} {parts[1]}"
        lat = float(parts[2])
        lon = float(parts[3])
        # parts[4]=depth; [5]=MD [6]=ML [7]=Mw — ML yoksa Mw/MD
        mag = None
        for idx in (6, 7, 5):
            tok = parts[idx]
            if tok in ("-.-", "", "None"):
                continue
            mag = float(tok)
            break
        if mag is None:
            return None
        place = " ".join(parts[8:])
        for junk in ("İlksel", "Ilksel", "REVIZE01", "REVIZE"):
            place = place.replace(junk, "")
        place = place.strip() or "konum yok"
    except (ValueError, IndexError):
        return None
    return {
        "eventID": f"kandilli:{when}:{lat:.3f}:{lon:.3f}:{mag:.1f}",
        "magnitude": mag,
        "latitude": lat,
        "longitude": lon,
        "location": place,
        "date": when,
        "source": "Kandilli",
    }


def fetch_kandilli() -> list[dict[str, Any]]:
    raw = _http_get(KANDILLI)
    text = None
    for enc in ("windows-1254", "iso-8859-9", "utf-8", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    if text is None:
        return []
    pre = re.search(r"<pre[^>]*>(.*?)</pre>", text, re.I | re.S)
    block = pre.group(1) if pre else text
    out: list[dict[str, Any]] = []
    for line in block.splitlines():
        if not re.match(r"^\d{4}\.\d{2}\.\d{2}", line.strip()):
            continue
        ev = parse_kandilli_line(line)
        if ev and _mag(ev) > 0:
            out.append(ev)
    return out


def _source_set(raw: Any) -> set[str]:
    if not isinstance(raw, str) or not raw.strip():
        return set()
    return {p for p in raw.split("+") if p}


def merge_events(*batches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Aynı parmak izi → tek kayıt; kaynakları birleştir (hangisi önce geldiyse kalsın)."""
    by_fp: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for batch in batches:
        for ev in batch:
            fp = fingerprint(ev)
            if fp not in by_fp:
                by_fp[fp] = dict(ev)
                by_fp[fp]["eventID"] = fp
                order.append(fp)
            else:
                cur = by_fp[fp]
                srcs = _source_set(cur.get("source")) | _source_set(ev.get("source"))
                cur["source"] = "+".join(sorted(srcs))
                if _mag(ev) > _mag(cur):
                    cur["magnitude"] = _mag(ev)
                if not cur.get("location") and ev.get("location"):
                    cur["location"] = ev["location"]
    return [by_fp[fp] for fp in order]


def _log_partial_errors(errors: list[str]) -> None:
    """AFAD 500 vb. — journal spam önle (aynı hata 15dk'da bir)."""
    key = ";".join(errors)
    now = time.time()
    data: dict[str, Any] = {}
    try:
        if PARTIAL_WARN_PATH.is_file():
            data = json.loads(PARTIAL_WARN_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        data = {}
    if data.get("key") == key and now - float(data.get("ts", 0)) < PARTIAL_WARN_MIN_SEC:
        return
    print(f"[quake] kısmi: {key}", file=sys.stderr)
    try:
        PARTIAL_WARN_PATH.parent.mkdir(parents=True, exist_ok=True)
        PARTIAL_WARN_PATH.write_text(
            json.dumps({"key": key, "ts": now}, ensure_ascii=False),
            encoding="utf-8",
        )
    except OSError:
        pass


def fetch_events() -> list[dict[str, Any]]:
    afad: list[dict[str, Any]] = []
    kandilli: list[dict[str, Any]] = []
    errors: list[str] = []
    with ThreadPoolExecutor(max_workers=2) as pool:
        fut_a = pool.submit(fetch_afad)
        fut_k = pool.submit(fetch_kandilli)
        try:
            afad = fut_a.result()
        except (OSError, TimeoutError, json.JSONDecodeError, urllib.error.URLError, ValueError) as exc:
            errors.append(f"AFAD:{exc}")
        try:
            kandilli = fut_k.result()
        except (OSError, TimeoutError, urllib.error.URLError, ValueError) as exc:
            errors.append(f"Kandilli:{exc}")
    if errors and not afad and not kandilli:
        raise RuntimeError("; ".join(errors))
    if errors:
        _log_partial_errors(errors)
    return merge_events(afad, kandilli)


def due_events(events: list[dict[str, Any]], state: dict[str, Any], now_ts: float) -> list[dict[str, Any]]:
    seen = set(state.get("seen") or [])
    sent_ts = [float(x) for x in (state.get("sent_ts") or [])]
    last = state.get("last") if isinstance(state.get("last"), dict) else None
    night = is_night(datetime.fromtimestamp(now_ts).astimezone())

    # İlk koşu: mevcut listeyi "görüldü" say — tarihî deprem spam’i yok
    if not state.get("bootstrapped"):
        for ev in events:
            seen.add(fingerprint(ev))
        state["seen"] = list(seen)[-800:]
        state["sent_ts"] = sent_ts
        state["last"] = last
        state["bootstrapped"] = True
        return []

    due: list[dict[str, Any]] = []
    for ev in events:
        eid = fingerprint(ev)
        if not eid or eid in seen:
            continue
        # Yeni olay işaretle (eşik altı da) — sonra tekrar bakma
        seen.add(eid)
        ets = _event_ts(ev)
        if ets is not None and now_ts - ets > MAX_EVENT_AGE_SEC:
            continue
        if not qualifies(ev, night=night):
            continue
        if is_aftershock(ev, last, now_ts):
            continue
        if hour_blocked(sent_ts, now_ts, _mag(ev)):
            continue
        due.append(ev)
        sent_ts.append(now_ts)
        loc = _latlon(ev) or (0.0, 0.0)
        last = {"mag": _mag(ev), "ts": now_ts, "lat": loc[0], "lon": loc[1]}
    state["seen"] = list(seen)[-800:]
    state["sent_ts"] = [t for t in sent_ts if now_ts - t < 86400][-50:]
    state["last"] = last
    state["bootstrapped"] = True
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
    sample = (
        "2026.08.27 14:16:09  40.8050   28.0587       10.2      -.-  2.7  -.-   "
        "MARMARA DENIZI                                    İlksel"
    )
    k = parse_kandilli_line(sample)
    assert k and abs(_mag(k) - 2.7) < 0.01 and k["source"] == "Kandilli", k
    a = {
        "magnitude": 2.7,
        "latitude": 40.80,
        "longitude": 28.06,
        "date": "2026.08.27 14:16:09",
        "source": "AFAD",
        "eventID": "x",
    }
    merged = merge_events([a], [k])
    assert len(merged) == 1, merged
    assert merged[0]["source"] == "AFAD+Kandilli", merged[0]["source"]
    # tekrar merge: kaynak şişmesin
    again = merge_events(merged, [a])
    assert again[0]["source"] == "AFAD+Kandilli", again[0]["source"]
    # bootstrap: ilk tur boş due
    st: dict[str, Any] = {}
    now = datetime(2026, 8, 25, 12, tzinfo=timezone.utc).timestamp()
    fresh = {
        "magnitude": 3.6,
        "latitude": 40.8,
        "longitude": 28.5,
        "date": datetime.fromtimestamp(now, tz=timezone(timedelta(hours=3))).strftime(
            "%Y.%m.%d %H:%M:%S"
        ),
        "source": "Kandilli",
        "eventID": "fresh",
    }
    assert due_events([fresh], st, now) == []
    assert st.get("bootstrapped") is True
    # ikinci tur: yeni fp → uyarı
    fresh2 = dict(fresh)
    fresh2["latitude"] = 40.81
    fresh2["longitude"] = 28.51
    due2 = due_events([fresh2], st, now)
    assert len(due2) == 1, due2
    print("[quake-alert] self-check OK")


def main() -> int:
    if "--self-check" in sys.argv:
        self_check()
        return 0
    try:
        events = fetch_events()
    except (OSError, TimeoutError, json.JSONDecodeError, urllib.error.URLError, ValueError, RuntimeError) as exc:
        print(f"[quake] fetch fail: {exc}", file=sys.stderr)
        return 0
    state = load_state(STATE_PATH)
    due = due_events(events, state, time.time())
    try:
        save_state(STATE_PATH, state)
    except OSError as exc:
        print(f"[quake] state yazilamadi: {exc}", file=sys.stderr)
    for ev in due:
        print(format_msg(ev))
        print("---")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
