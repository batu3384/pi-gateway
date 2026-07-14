#!/usr/bin/env bash
# Sabah ozeti systemd timer kurulumu
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

log() { echo "[morning-timer] $*"; }

notify_enabled() { [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; }
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
notify_enabled || { log "Telegram eksik — atlandi"; exit 0; }

for unit in pi-gateway-morning.service pi-gateway-morning.timer; do
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; exit 1; }
  sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
  sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
    sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true
done

sudo systemctl daemon-reload
sudo systemctl enable --now pi-gateway-morning.timer
log "Aktif: her gun 08:00 (Europe/Istanbul sistem saati)"
log "Test: REMOTE_DIR=$REMOTE_DIR bash $REMOTE_DIR/scripts/pi/morning-summary.sh"
