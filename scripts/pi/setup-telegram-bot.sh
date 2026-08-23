#!/usr/bin/env bash
# Telegram bot systemd kurulumu
# Cutover: run AFTER setup-hermes-gateway.sh when HERMES_TELEGRAM_GATEWAY=true
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
log() { echo "[telegram-bot-setup] $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }

unit=pi-gateway-telegram-bot.service
hermes_unit=hermes-gateway.service

_tg_ready() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

_enable_poller_fallback() {
  _tg_ready || load_telegram_from_hermes || return 1
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || return 1
  sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
  sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
    sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$unit" 2>/dev/null || true
  log "Fallback: panel poller enable (Hermes yok)"
}

# Hermes owns getUpdates — guard BEFORE token early-exit
if [[ "${HERMES_TELEGRAM_GATEWAY:-}" == "true" ]]; then
  if ! systemctl is-active "$hermes_unit" &>/dev/null; then
    log "HATA: HERMES_TELEGRAM_GATEWAY=true ama $hermes_unit active degil — once setup-hermes-gateway.sh"
    _enable_poller_fallback || log "WARN: fallback poller da yok (token hermes/.env veya pi .env gerekli)"
    exit 1
  fi
  if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
    sudo systemctl disable --now "$unit" || {
      log "HATA: $unit disable basarisiz — cift getUpdates riski"
      exit 1
    }
  fi
  log "HERMES_TELEGRAM_GATEWAY=true — panel poller kapali (Hermes inbox)"
  exit 0
fi

if ! _tg_ready; then
  log "Telegram eksik — atlandi"
  exit 0
fi

[[ -f "$REMOTE_DIR/host/systemd/$unit" ]] || { log "HATA: $unit yok"; exit 1; }
sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || \
  sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$unit" 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable --now "$unit"
log "Aktif: pi-gateway-telegram-bot.service"
log "Test: REMOTE_DIR=$REMOTE_DIR bash $REMOTE_DIR/scripts/pi/telegram-menu.sh"
