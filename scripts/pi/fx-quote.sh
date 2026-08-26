#!/usr/bin/env bash
# Kompakt piyasa satırı — 1 FX istek, çapraz kur, kısa timeout, cache.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="${SCRIPT_DIR}/../lib/archive-bulletin.sh"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 - <<'PY'
from __future__ import annotations

def cross_try(rates: dict, quote: str) -> float:
    return float(rates["TRY"]) / float(rates[quote])

rates = {"TRY": 41.5, "EUR": 0.85, "GBP": 0.74}
assert abs(cross_try(rates, "EUR") - (41.5 / 0.85)) < 1e-9
assert abs(cross_try(rates, "GBP") - (41.5 / 0.74)) < 1e-9
print("[fx-quote] self-check OK")
PY
  exit 0
fi

python3 - <<'PY' | bash "$ARCHIVE" fx
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

UA = "pi-gateway-fx-quote/2"
TIMEOUT = 3
TTL = int(os.environ.get("FX_QUOTE_TTL_SEC", "60"))


def cache_path() -> Path:
    env = os.environ.get("FX_QUOTE_CACHE")
    if env:
        return Path(env)
    for p in (
        Path("/var/lib/pi-gateway/fx-quote.cache"),
        Path("/tmp/pi-gateway-fx-quote.cache"),
    ):
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            if os.access(p.parent, os.W_OK):
                return p
        except OSError:
            continue
    return Path("/tmp/pi-gateway-fx-quote.cache")


def close_path() -> Path:
    env = os.environ.get("FX_QUOTE_CLOSE")
    if env:
        return Path(env)
    for p in (
        Path("/var/lib/pi-gateway/fx-close.json"),
        Path("/tmp/pi-gateway-fx-close.json"),
    ):
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            if os.access(p.parent, os.W_OK):
                return p
        except OSError:
            continue
    return Path("/tmp/pi-gateway-fx-close.json")


def load_close() -> dict:
    try:
        data = json.loads(close_path().read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_close(today: str, rates: dict, prev: dict) -> None:
    try:
        close_path().write_text(
            json.dumps({"date": today, "rates": rates, "prev": prev}, ensure_ascii=False),
            encoding="utf-8",
        )
    except OSError:
        pass


def delta_s(now: float, prev: float | None, digits: int = 4) -> str:
    if prev is None:
        return ""
    d = now - prev
    sign = "+" if d >= 0 else "−"
    return f"  ({sign}{fmt(abs(d), digits)})"


def load_cache() -> str | None:
    path = cache_path()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if time.time() - float(data["ts"]) <= TTL:
            text = data.get("text")
            return text if isinstance(text, str) and text.strip() else None
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
    return None


def save_cache(text: str) -> None:
    try:
        path = cache_path()
        path.write_text(json.dumps({"ts": time.time(), "text": text}), encoding="utf-8")
    except OSError:
        pass


def get(url: str) -> dict | None:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for _ in range(2):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError, ValueError):
            time.sleep(0.4)
    return None


def fmt(n: float, digits: int = 2) -> str:
    return f"{n:,.{digits}f}".replace(",", "X").replace(".", ",").replace("X", ".")


cached = load_cache()
if cached:
    print(cached)
    raise SystemExit(0)

now_dt = datetime.now(timezone.utc).astimezone()
today = now_dt.strftime("%Y-%m-%d")
close = load_close()
prev_rates = close.get("prev") if close.get("date") == today else close.get("rates")
if not isinstance(prev_rates, dict):
    prev_rates = {}

usd = get("https://open.er-api.com/v6/latest/USD")
gold = get("https://finans.truncgil.com/today.json")

lines = [
    "📋 Pi Gateway · Bülten",
    f"📈 Piyasa — {now_dt.strftime('%d.%m.%Y')}",
    "─────────",
]
ok = 0
cur: dict = {}
rates = usd.get("rates") if usd and usd.get("result") == "success" else None
if isinstance(rates, dict) and "TRY" in rates:
    usdtry = float(rates["TRY"])
    cur["USDTRY"] = usdtry
    prev = float(prev_rates["USDTRY"]) if "USDTRY" in prev_rates else None
    lines.append(f"USD/TRY  {fmt(usdtry, 4)}{delta_s(usdtry, prev)}")
    ok += 1
    for code, label, key in (("EUR", "EUR/TRY", "EURTRY"), ("GBP", "GBP/TRY", "GBPTRY")):
        if code in rates and float(rates[code]) != 0:
            val = float(rates["TRY"]) / float(rates[code])
            cur[key] = val
            p = float(prev_rates[key]) if key in prev_rates else None
            lines.append(f"{label}  {fmt(val, 4)}{delta_s(val, p)}")
            ok += 1
if isinstance(gold, dict):
    def gold_price(key: str) -> float | None:
        item = gold.get(key)
        if isinstance(item, dict):
            for field in ("Satış", "Satis"):
                raw = item.get(field)
                if raw is None:
                    continue
                try:
                    return float(str(raw).replace(".", "").replace(",", "."))
                except ValueError:
                    continue
        return None

    gram = gold_price("gram-altin")
    ceyrek = gold_price("ceyrek-altin")
    if gram:
        cur["GRAM"] = gram
        p = float(prev_rates["GRAM"]) if "GRAM" in prev_rates else None
        lines.append(f"Gram Altın  {fmt(gram, 2)} ₺{delta_s(gram, p, 2)}")
        ok += 1
    if ceyrek:
        cur["CEYREK"] = ceyrek
        p = float(prev_rates["CEYREK"]) if "CEYREK" in prev_rates else None
        lines.append(f"Çeyrek      {fmt(ceyrek, 2)} ₺{delta_s(ceyrek, p, 2)}")
        ok += 1

if ok:
    lines.append("─────────")
    lines.append("Pi Gateway · otomatik bülten")
    save_close(today, cur, prev_rates if prev_rates else cur)

text = "📊 Piyasa verisi alınamadı — bu tur atlandı." if ok == 0 else "\n".join(lines)
if ok:
    save_cache(text)
print(text)
PY
