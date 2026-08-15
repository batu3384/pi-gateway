#!/usr/bin/env bash
# macOS Syncthing: kurulum, Pi eslestirme, Projects klasoru
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_project_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
PI_STATIC_IP="${PI_STATIC_IP:-}"
SYNCTHING_MAC_DEVICE_ID="${SYNCTHING_MAC_DEVICE_ID:-}"
SYNCTHING_FOLDER_ID="${SYNCTHING_FOLDER_ID:-projects}"
SYNCTHING_FOLDER_LABEL="${SYNCTHING_FOLDER_LABEL:-Projects}"
MAC_PROJECTS_DIR="${MAC_PROJECTS_DIR:-$HOME/Projects}"
log() { echo "[mac-syncthing] $*"; }
[[ "$(uname)" == "Darwin" ]] || { log "Sadece macOS"; exit 1; }
[[ -n "$PI_STATIC_IP" ]] || { log "HATA: PI_STATIC_IP gerekli (.env)"; exit 1; }
if ! command -v syncthing >/dev/null 2>&1; then
  log "Syncthing kuruluyor (brew)..."
  brew install syncthing
fi
if ! pgrep -x syncthing >/dev/null 2>&1; then
  log "Syncthing baslatiliyor..."
  brew services start syncthing
  sleep 4
fi
CONF="$HOME/Library/Application Support/Syncthing/config.xml"
[[ -f "$CONF" ]] || { log "HATA: Syncthing config yok — biraz bekleyip tekrar dene"; exit 1; }
MAC_API="$(sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' "$CONF" | head -1)"
MAC_ID="$(curl -fsS -H "X-API-Key: $MAC_API" http://127.0.0.1:8384/rest/system/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["myID"])')"
if [[ -z "$SYNCTHING_MAC_DEVICE_ID" ]]; then
  log "Mac Device ID: $MAC_ID"
  log ".env dosyasina ekle: SYNCTHING_MAC_DEVICE_ID=$MAC_ID"
fi
PI_ID="$(curl -fsS -H "X-API-Key: $MAC_API" "http://${PI_STATIC_IP}:8384/rest/system/status" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("myID",""))' 2>/dev/null || true)"
[[ -n "$PI_ID" ]] || PI_ID="$(ssh -o ConnectTimeout=5 "${PI_USER:-pi}@${PI_STATIC_IP}" \
  "docker exec syncthing sed -n 's:.*<device id=\"\\([^\"]*\\)\".*:\\1:p' /var/syncthing/config/config.xml | head -1" 2>/dev/null || true)"
[[ -n "$PI_ID" ]] || { log "HATA: Pi Device ID alinamadi"; exit 1; }
api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" -H "X-API-Key: $MAC_API" -H "Content-Type: application/json" \
      -d "$data" "http://127.0.0.1:8384${path}" >/dev/null
  else
    curl -fsS -X "$method" -H "X-API-Key: $MAC_API" "http://127.0.0.1:8384${path}"
  fi
}
has_device() {
  api GET "/rest/config/devices" | python3 -c "
import json,sys
t=sys.argv[1]
sys.exit(0 if any(d.get('deviceID')==t for d in json.load(sys.stdin)) else 1)
" "$1"
}
has_folder() {
  api GET "/rest/config/folders" | python3 -c "
import json,sys
sys.exit(0 if any(f.get('id')==sys.argv[1] for f in json.load(sys.stdin)) else 1)
" "$1"
}
if ! has_device "$PI_ID"; then
  api POST "/rest/config/devices" "$(python3 - <<PY
import json
print(json.dumps({
  "deviceID": "$PI_ID",
  "name": "Pi-Gateway",
  "addresses": ["tcp://${PI_STATIC_IP}:22000", "dynamic"],
  "autoAcceptFolders": True,
}))
PY
)"
  log "Pi cihazi eklendi"
fi
mkdir -p "$MAC_PROJECTS_DIR"
if ! has_folder "$SYNCTHING_FOLDER_ID"; then
  api POST "/rest/config/folders" "$(python3 - <<PY
import json
print(json.dumps({
  "id": "$SYNCTHING_FOLDER_ID",
  "label": "$SYNCTHING_FOLDER_LABEL",
  "filesystemType": "basic",
  "path": "$MAC_PROJECTS_DIR",
  "type": "sendreceive",
  "devices": [
    {"deviceID": "$MAC_ID", "introducedBy": ""},
    {"deviceID": "$PI_ID", "introducedBy": ""},
  ],
  "rescanIntervalS": 3600,
  "fsWatcherEnabled": True,
  "fsWatcherDelayS": 10,
  "versioning": {"type": "", "params": {}},
}))
PY
)"
  log "Projects klasoru: $MAC_PROJECTS_DIR"
fi
log "Mac UI: http://127.0.0.1:8384"
log "Pi UI:  http://${PI_STATIC_IP}:8384 veya http://sync.home"
log "Tamamlandi"
