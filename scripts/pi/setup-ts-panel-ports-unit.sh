#!/usr/bin/env bash
# Install + enable oneshot: Tailscale IP:PORT DNAT (panel asset 404 fix)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[ts-panel-ports-unit] $*"; }
unit=pi-gateway-ts-panel-ports.service
src="$REMOTE_DIR/host/systemd/$unit"
[[ -f "$src" ]] || { log "HATA: $src yok"; exit 1; }
sudo cp "$src" "/etc/systemd/system/$unit"
sudo sed -i \
  -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
  -e "s|PI_USER|${USER}|g" \
  "/etc/systemd/system/$unit" 2>/dev/null || \
  sudo sed -i '' \
    -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
    -e "s|PI_USER|${USER}|g" \
    "/etc/systemd/system/$unit" 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable --now "$unit"
# Apply immediately (unit RemainAfterExit; also run script for live rules)
bash "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" || true
log "Aktif: $unit"
