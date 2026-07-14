#!/usr/bin/env bash
# Syncthing: Mac cihazini ve Projects klasorunu yapilandirir
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

SYNCTHING_MAC_DEVICE_ID="${SYNCTHING_MAC_DEVICE_ID:-}"
SYNCTHING_FOLDER_ID="${SYNCTHING_FOLDER_ID:-projects}"
SYNCTHING_FOLDER_LABEL="${SYNCTHING_FOLDER_LABEL:-Projects}"
PI_STATIC_IP="${PI_STATIC_IP:-192.168.1.112}"
SYNCTHING_PORT="${SYNCTHING_PORT:-8384}"

log() { echo "[syncthing-setup] $*"; }

[[ -n "$SYNCTHING_MAC_DEVICE_ID" ]] || { log "SYNCTHING_MAC_DEVICE_ID bos — atlandi"; exit 0; }

docker ps --format '{{.Names}}' | grep -q '^syncthing$' || { log "syncthing container yok"; exit 0; }

APIKEY="$(docker exec syncthing sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' /var/syncthing/config/config.xml | head -1)"
PI_ID="$(docker exec syncthing sed -n 's:.*<device id="\([^"]*\)".*:\1:p' /var/syncthing/config/config.xml | head -1)"
BASE="http://127.0.0.1:${SYNCTHING_PORT}"

api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" -H "X-API-Key: $APIKEY" -H "Content-Type: application/json" \
      -d "$data" "${BASE}${path}" >/dev/null
  else
    curl -fsS -X "$method" -H "X-API-Key: $APIKEY" "${BASE}${path}" 2>/dev/null
  fi
}

device_exists() {
  api GET "/rest/config/devices" | python3 -c "
import json,sys
target=sys.argv[1]
for d in json.load(sys.stdin):
    if d.get('deviceID') == target:
        sys.exit(0)
sys.exit(1)
" "$SYNCTHING_MAC_DEVICE_ID"
}

folder_exists() {
  api GET "/rest/config/folders" | python3 -c "
import json,sys
target=sys.argv[1]
for f in json.load(sys.stdin):
    if f.get('id') == target:
        sys.exit(0)
sys.exit(1)
" "$SYNCTHING_FOLDER_ID"
}

if ! device_exists; then
  api POST "/rest/config/devices" "$(python3 - <<PY
import json
print(json.dumps({
  "deviceID": "$SYNCTHING_MAC_DEVICE_ID",
  "name": "Mac",
  "addresses": ["dynamic"],
  "autoAcceptFolders": True,
}))
PY
)"
  log "Mac cihazi eklendi"
else
  log "Mac cihazi zaten kayitli"
fi

mkdir -p "${REMOTE_DIR}/data/projects"
docker exec syncthing mkdir -p "/var/syncthing/Projects"

if ! folder_exists; then
  api POST "/rest/config/folders" "$(python3 - <<PY
import json
print(json.dumps({
  "id": "$SYNCTHING_FOLDER_ID",
  "label": "$SYNCTHING_FOLDER_LABEL",
  "filesystemType": "basic",
  "path": "/var/syncthing/Projects",
  "type": "sendreceive",
  "devices": [
    {"deviceID": "$PI_ID", "introducedBy": ""},
    {"deviceID": "$SYNCTHING_MAC_DEVICE_ID", "introducedBy": ""},
  ],
  "rescanIntervalS": 3600,
  "fsWatcherEnabled": True,
  "fsWatcherDelayS": 10,
  "versioning": {"type": "", "params": {}},
}))
PY
)"
  log "Projects klasoru olusturuldu"
else
  log "Projects klasoru zaten var"
fi

log "Pi Device ID: ${PI_ID}"
log "Tamamlandi"
