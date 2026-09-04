#!/usr/bin/env bash
# Query log'dan Pi'de filtrelenmeyen reklam adayi domainleri — user-rules sniper onerisi
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env" >&2; exit 1; }
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"

PI_IP="${PI_STATIC_IP:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
LIMIT="${SUGGEST_SNIPER_QUERY_LIMIT:-3000}"
TOP_N="${SUGGEST_SNIPER_TOP:-15}"
HOURS="${SUGGEST_SNIPER_HOURS:-24}"

[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[sniper] HATA: AGH_ADMIN_PASSWORD bos" >&2; exit 1; }

COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
agh_login "http://127.0.0.1:${ADGUARD_WEB_PORT}" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" \
  || { echo "[sniper] HATA: AdGuard login" >&2; exit 1; }

export COOKIE ADGUARD_WEB_PORT LIMIT TOP_N HOURS PI_IP REMOTE_DIR
python3 - <<'PY'
import json
import os
import re
import subprocess
import time
from collections import Counter
from pathlib import Path
from urllib.parse import quote

cookie = os.environ["COOKIE"]
port = os.environ["ADGUARD_WEB_PORT"]
limit = int(os.environ["LIMIT"])
top_n = int(os.environ["TOP_N"])
hours = int(os.environ["HOURS"])
remote_dir = os.environ["REMOTE_DIR"]
pi_ip = os.environ.get("PI_IP", "")

def curl_api(path: str) -> dict:
    out = subprocess.check_output(
        ["curl", "-fsS", "-b", cookie, f"http://127.0.0.1:{port}{path}"],
        text=True,
    )
    return json.loads(out)

regression_path = Path(remote_dir) / "config/adguard/filter-lists.json"
allow_hosts: set[str] = set()
if regression_path.is_file():
    data = json.loads(regression_path.read_text())
    allow_hosts = {h.lower() for h in data.get("regression", {}).get("must_not_block_hosts", [])}

ad_re = re.compile(
    r"(^|[.-])(ads?|adserver|adnxs|adsrv|doubleclick|googlesyndication|"
    r"amazon-adsystem|taboola|outbrain|criteo|pubmatic|rubicon|"
    r"scorecardresearch|moatads|applovin|unityads|inmobi|vungle|"
    r"samsungads|smartclip|springserve|gemius|yandex)[.-]|"
    r"adservice\.|pagead\.|adform\.|adtech\.|adcolony\.|"
    r"ads\.|tracking\.|telemetry\.",
    re.I,
)
cutoff = time.time() - hours * 3600
rows = curl_api(f"/control/querylog?older_than=&limit={limit}").get("data", [])
counts: Counter[str] = Counter()
clients: dict[str, set[str]] = {}

for row in rows:
  ts = row.get("time") or row.get("T") or 0
  if isinstance(ts, str):
      continue
  if ts > 1_000_000_000_000:
      ts /= 1000
  if ts and ts < cutoff:
      continue
  reason = str(row.get("reason", ""))
  if reason not in ("NotFilteredNotFound", "NotFilteredWhiteList"):
      continue
  host = str(row.get("host") or row.get("domain") or "").lower().rstrip(".")
  if not host or host in allow_hosts:
      continue
  if host.endswith(".home") or host.endswith(".local"):
      continue
  if ad_re.search(host):
      counts[host] += 1
      client = str(row.get("client") or row.get("client_id") or "")
      if client:
          clients.setdefault(host, set()).add(client)

print(f"=== DNS sniper onerileri (son {hours}h, reklam adayi, NotFiltered) ===")
if not counts:
    print("[sniper] Aday yok — query log temiz veya pencere dar.")
    print("  Ipucu: reklam gorunurken tekrar calistir; SUGGEST_SNIPER_HOURS=6")
    raise SystemExit(0)

print(f"Top {top_n} (user-rules.txt'e ||host^$important ekleyin):")
for host, n in counts.most_common(top_n):
    who = ",".join(sorted(clients.get(host, []))[:3]) or "?"
    print(f"  {n:4d}x  {host}  (istemci: {who})")

print("")
print("Kontrol (Pi DNS):")
for host, _ in counts.most_common(min(3, top_n)):
    if not pi_ip:
        break
    chk = curl_api(f"/control/filtering/check_host?name={quote(host, safe='')}")
    reason = chk.get("reason", "?")
    print(f"  {host}: {reason}")
PY
