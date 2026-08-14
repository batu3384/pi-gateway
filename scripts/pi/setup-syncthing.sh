#!/usr/bin/env bash
# Syncthing: Mac cihazini ve Projects klasorunu yapilandirir
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
SYNCTHING_MAC_DEVICE_ID="${SYNCTHING_MAC_DEVICE_ID:-}"
SYNCTHING_FOLDER_ID="${SYNCTHING_FOLDER_ID:-projects}"
SYNCTHING_FOLDER_LABEL="${SYNCTHING_FOLDER_LABEL:-Projects}"
PI_STATIC_IP="${PI_STATIC_IP:-}"
SYNCTHING_PORT="${SYNCTHING_PORT:-8384}"
log() { echo "[syncthing-setup] $*"; }
[[ -n "$PI_STATIC_IP" ]] || { log "HATA: PI_STATIC_IP bos"; exit 1; }
[[ -n "$SYNCTHING_MAC_DEVICE_ID" ]] || { log "SYNCTHING_MAC_DEVICE_ID bos — atlandi"; exit 0; }
docker ps --format '{{.Names}}' | grep -q '^syncthing$' || { log "syncthing container yok"; exit 0; }
APIKEY="$(docker exec syncthing sed -n 's:.*<apikey>\([^<]*\)</apikey>.*:\1:p' /var/syncthing/config/config.xml 2>/dev/null | head -1 || true)"
PI_ID="$(docker exec syncthing sed -n 's:.*<device id="\([^"]*\)".*:\1:p' /var/syncthing/config/config.xml 2>/dev/null | head -1 || true)"
[[ -n "$APIKEY" && -n "$PI_ID" ]] || { log "Syncthing config okunamadi"; exit 1; }
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
# Pi'nin LAN uzerinden sync adresini duyur (Docker NAT)
export BASE APIKEY PI_STATIC_IP
python3 <<'PY'
import json, os, subprocess, sys
base = os.environ["BASE"]
apikey = os.environ["APIKEY"]
pi_ip = os.environ["PI_STATIC_IP"]
addr = f"tcp://{pi_ip}:22000"
raw = subprocess.check_output(
    ["curl", "-fsS", "-H", f"X-API-Key: {apikey}", f"{base}/rest/config/options"],
    text=True,
)
opts = json.loads(raw)
changed = False
for key, val in [
    ("globalAnnounceEnabled", True),
    ("localAnnounceEnabled", True),
    ("natEnabled", True),
]:
    if opts.get(key) is not val:
        opts[key] = val
        changed = True
if changed:
    subprocess.run(
        [
            "curl", "-fsS", "-X", "PUT",
            "-H", f"X-API-Key: {apikey}",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(opts),
            f"{base}/rest/config/options",
        ],
        check=True,
    )
    print("[syncthing-setup] announce/nat secenekleri guncellendi")
devices = json.loads(subprocess.check_output(
    ["curl", "-fsS", "-H", f"X-API-Key: {apikey}", f"{base}/rest/config/devices"],
    text=True,
))
my_id = json.loads(subprocess.check_output(
    ["curl", "-fsS", "-H", f"X-API-Key: {apikey}", f"{base}/rest/system/status"],
    text=True,
)).get("myID")
for dev in devices:
    if dev.get("deviceID") != my_id:
        continue
    addrs = list(dev.get("addresses") or [])
    if addr not in addrs:
        addrs.insert(0, addr)
        dev["addresses"] = addrs
        subprocess.run(
            [
                "curl", "-fsS", "-X", "PUT",
                "-H", f"X-API-Key: {apikey}",
                "-H", "Content-Type: application/json",
                "-d", json.dumps(dev),
                f"{base}/rest/config/devices/{my_id}",
            ],
            check=True,
        )
        print(f"[syncthing-setup] Pi sync adresi: {addr}")
    break
PY
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
