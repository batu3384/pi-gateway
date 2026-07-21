#!/usr/bin/env bash
# AdGuard kalici istemci isimlerini NetAlertX'e cek (dns.home kaynak)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"

AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"

log() { echo "[adguard-import] $*"; }

[[ -n "$AGH_ADMIN_PASSWORD" ]] || { log "AGH_ADMIN_PASSWORD bos"; exit 1; }
docker ps --format '{{.Names}}' | grep -q '^netalertx$' || { log "netalertx yok"; exit 0; }

COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT

agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" || {
  log "AdGuard login basarisiz"
  exit 1
}

export BASE COOKIE
json_payload="$(python3 <<'PY'
import json
import os
import re
import subprocess

base = os.environ["BASE"]
cookie = os.environ["COOKIE"]

def curl(path):
    return subprocess.check_output(
        [
            "curl", "-fsS", "-b", cookie,
            f"{base}{path}",
            "-H", "Content-Type: application/json",
        ],
        text=True,
    )

def is_mac(value: str) -> bool:
    return bool(re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", value.lower()))

def is_lan_ip(ip: str) -> bool:
    return bool(re.match(r"^192\.168\.\d+\.\d+$", ip or ""))

clients_json = json.loads(curl("/control/clients"))
by_mac = {}
for client in clients_json.get("clients") or []:
    name = (client.get("name") or "").strip()
    if not name:
        continue
    for ident in client.get("ids") or []:
        ident_l = ident.lower()
        if is_mac(ident_l):
            by_mac[ident_l] = name

for entry in clients_json.get("auto_clients") or []:
    ip = (entry.get("ip") or "").strip()
    name = (entry.get("name") or "").strip()
    if name and is_lan_ip(ip):
        by_mac.setdefault(f"ip:{ip}", name)

print(json.dumps({"by_mac": by_mac}))
PY
)"

docker exec -i -e NAX_IMPORT_JSON="$json_payload" netalertx python3 -c '
import json
import os
import sqlite3

data = json.loads(os.environ["NAX_IMPORT_JSON"])
by_mac = data.get("by_mac") or {}

conn = sqlite3.connect("/data/db/app.db")
rows = conn.execute(
    "SELECT devMac, devName, devLastIP FROM Devices WHERE devMac != '\''internet'\''"
).fetchall()

updated = skipped = 0
for mac, cur_name, ip in rows:
    mac_l = mac.lower()
    new_name = by_mac.get(mac_l)
    if not new_name and ip:
        new_name = by_mac.get(f"ip:{ip}")
    if not new_name or new_name == cur_name:
        skipped += 1
        continue
    conn.execute("UPDATE Devices SET devName=? WHERE devMac=?", (new_name, mac))
    print(f"[adguard-import] {ip or mac}: {cur_name!r} -> {new_name!r}")
    updated += 1

conn.commit()
conn.close()
print(f"[adguard-import] {updated} cihaz guncellendi, {skipped} atlandi")
'
