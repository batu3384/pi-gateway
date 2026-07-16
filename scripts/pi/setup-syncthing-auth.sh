#!/usr/bin/env bash
# Syncthing GUI sifresini .env ile senkronlar
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

SYNCTHING_GUI_USER="${SYNCTHING_GUI_USER:-batu}"
SYNCTHING_GUI_PASSWORD="${SYNCTHING_GUI_PASSWORD:-}"
SYNCTHING_PORT="${SYNCTHING_PORT:-8384}"

log() { echo "[syncthing-auth] $*"; }

[[ -n "$SYNCTHING_GUI_PASSWORD" ]] || { log "SYNCTHING_GUI_PASSWORD bos — atlandi"; exit 0; }
docker ps --format '{{.Names}}' | grep -q '^syncthing$' || { log "syncthing container yok"; exit 0; }

APIKEY="$(docker exec syncthing sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' /var/syncthing/config/config.xml | head -1)"
[[ -n "$APIKEY" ]] || { log "API key bulunamadi"; exit 1; }

BASE="http://127.0.0.1:${SYNCTHING_PORT}"
HASH="$(docker run --rm httpd:2-alpine htpasswd -nbBC 10 "$SYNCTHING_GUI_USER" "$SYNCTHING_GUI_PASSWORD" | cut -d: -f2)"

export BASE APIKEY SYNCTHING_GUI_USER HASH

python3 <<'PY'
import json
import os
import subprocess
import sys

base = os.environ["BASE"]
apikey = os.environ["APIKEY"]
user = os.environ["SYNCTHING_GUI_USER"]
password_hash = os.environ["HASH"]

raw = subprocess.check_output(
    ["curl", "-fsS", "-H", f"X-API-Key: {apikey}", f"{base}/rest/config/gui"],
    text=True,
)
gui = json.loads(raw)

if gui.get("user") == user and gui.get("password") == password_hash:
    print("[syncthing-auth] zaten guncel")
    sys.exit(0)

gui["user"] = user
gui["password"] = password_hash
body = json.dumps(gui)

subprocess.run(
    [
        "curl", "-fsS", "-X", "PUT",
        "-H", f"X-API-Key: {apikey}",
        "-H", "Content-Type: application/json",
        "-d", body,
        f"{base}/rest/config/gui",
    ],
    check=True,
)
print(f"[syncthing-auth] GUI sifresi guncellendi: {user}")
PY

log "Tamamlandi"
