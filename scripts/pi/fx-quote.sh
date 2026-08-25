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

usd = get("https://open.er-api.com/v6/latest/USD")
gold = get("https://finans.truncgil.com/today.json")

lines = [
    "📊 Piyasa",
    datetime.now(timezone.utc).astimezone().strftime("%d.%m.%Y %H:%M"),
]
ok = 0
rates = usd.get("rates") if usd and usd.get("result") == "success" else None
if isinstance(rates, dict) and "TRY" in rates:
    lines.append(f"USD/TRY  {fmt(float(rates['TRY']), 4)}")
    ok += 1
    for code, label in (("EUR", "EUR/TRY"), ("GBP", "GBP/TRY")):
        if code in rates and float(rates[code]) != 0:
            lines.append(f"{label}  {fmt(float(rates['TRY']) / float(rates[code]), 4)}")
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
        lines.append(f"Gram Altın  {fmt(gram, 2)} ₺")
        ok += 1
    if ceyrek:
        lines.append(f"Çeyrek      {fmt(ceyrek, 2)} ₺")
        ok += 1

text = "📊 Piyasa verisi alınamadı — bu tur atlandı." if ok == 0 else "\n".join(lines)
if ok:
    save_cache(text)
print(text)
PY
