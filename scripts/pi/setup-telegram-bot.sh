#!/usr/bin/env bash
# Telegram bot systemd kurulumu
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

log() { echo "[telegram-bot-setup] $*"; }

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || {
  log "Telegram eksik — atlandi"
  exit 0
}

unit=pi-gateway-telegram-bot.service
[[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; exit 1; }

sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
  sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true

sudo systemctl daemon-reload
sudo systemctl enable --now "$unit"
log "Aktif: pi-gateway-telegram-bot.service"
log "Test: REMOTE_DIR=$REMOTE_DIR bash $REMOTE_DIR/scripts/pi/telegram-menu.sh"
