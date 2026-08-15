#!/usr/bin/env bash
# Install weekly SSD SMART check timer
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[ssd-smart-timer] $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[ssd-smart-timer] HATA: .env dotenv parser hatasi" >&2; exit 1; }
for unit in pi-gateway-ssd-smart.service pi-gateway-ssd-smart.timer; do
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; exit 1; }
  sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
  sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
    sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true
done
sudo systemctl daemon-reload
sudo systemctl enable --now pi-gateway-ssd-smart.timer
log "Aktif: Pazar 04:30"
log "Test: REMOTE_DIR=$REMOTE_DIR bash $REMOTE_DIR/scripts/pi/check-ssd-smart.sh"
