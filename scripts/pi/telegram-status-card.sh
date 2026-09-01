#!/usr/bin/env bash
# Sabit durum kartı — health timer + /menu
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARD_PY="${REMOTE_DIR}/scripts/lib/telegram-status-card.py"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
load_telegram_from_hermes || true
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[status-card] $*"; }
notify_enabled || { log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"; exit 1; }
[[ -f "$CARD_PY" ]] || { log "HATA: telegram-status-card.py yok"; exit 1; }

if [[ -x "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" ]]; then
  bash "$REMOTE_DIR/scripts/pi/setup-tailscale-panel-ports.sh" || log "WARN: ts-panel-ports"
fi

export LAN_DOMAIN PI_STATIC_IP PANEL_PROTOCOL ENABLE_TLS
export AGH_ADMIN_USER CADDY_AUTH_USER
export HERMES_TELEGRAM_GATEWAY
export DOZZLE_PORT ADGUARD_WEB_PORT N8N_PORT GRAFANA_PORT NETALERTX_PORT
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
export PI_GATEWAY_HEALTH_OK="${PI_GATEWAY_HEALTH_OK:-1}"

args=(apply)
for a in "$@"; do
  case "$a" in
    --force) args+=("$a") ;;
  esac
done
python3 "$CARD_PY" "${args[@]}"
