#!/usr/bin/env bash
# NetAlertX cihaz isimlerini AdGuard kalici istemcilere yansit (dns.home paneli)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/adguard-api.sh"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
DB="${REMOTE_DIR}/data/netalertx/db/app.db"
log() { echo "[adguard-clients] $*"; }
[[ -n "$AGH_ADMIN_PASSWORD" ]] || { log "AGH_ADMIN_PASSWORD bos"; exit 1; }
[[ -f "$DB" ]] || { log "NetAlertX DB yok"; exit 0; }
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" || {
  log "AdGuard login basarisiz"
  exit 1
}
export BASE COOKIE DB
python3 <<'PY'
import json
import os
import sqlite3
import subprocess
base = os.environ["BASE"]
cookie = os.environ["COOKIE"]
db = os.environ["DB"]
def curl(path, method="GET", data=None):
    cmd = [
        "curl", "-fsS", "-b", cookie,
        "-X", method,
        f"{base}{path}",
        "-H", "Content-Type: application/json",
    ]
    if data is not None:
        cmd += ["-d", json.dumps(data)]
    return subprocess.check_output(cmd, text=True)
existing = json.loads(curl("/control/clients"))
by_mac = {}
for c in existing.get("clients") or []:
    for ident in c.get("ids") or []:
        by_mac[ident.lower()] = c
conn = sqlite3.connect(db)
rows = conn.execute(
    "SELECT devMac, devName, devLastIP FROM Devices WHERE devMac != 'internet'"
).fetchall()
conn.close()
added = updated = skipped = 0
for mac, name, ip in rows:
    mac_l = mac.lower()
    if not mac_l:
        skipped += 1
        continue
    if not name or name in ("(name not found)", ip) or str(name).startswith("192.168."):
        skipped += 1
        continue
    if mac_l in by_mac:
        cur = by_mac[mac_l]
        old_name = cur.get("name")
        if old_name == name:
            skipped += 1
            continue
        data = {
            "name": name,
            "ids": cur.get("ids") or [mac_l],
            "use_global_settings": cur.get("use_global_settings", True),
            "filtering_enabled": cur.get("filtering_enabled", False),
            "parental_enabled": cur.get("parental_enabled", False),
            "safebrowsing_enabled": cur.get("safebrowsing_enabled", False),
            "safesearch_enabled": cur.get("safesearch_enabled", False),
            "ignore_querylog": cur.get("ignore_querylog", False),
            "ignore_statistics": cur.get("ignore_statistics", False),
        }
        payload = {"name": old_name, "data": data}
        curl("/control/clients/update", "POST", payload)
        print(f"[adguard-clients] guncellendi: {old_name!r} -> {name!r} ({mac_l})")
        updated += 1
    else:
        curl("/control/clients/add", "POST", {"name": name, "ids": [mac_l]})
        print(f"[adguard-clients] eklendi: {name} ({mac_l})")
        added += 1
print(f"[adguard-clients] Tamamlandi — {added} yeni, {updated} guncellendi, {skipped} atlandi")
PY
