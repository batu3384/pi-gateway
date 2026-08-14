#!/usr/bin/env bash
# Telegram: panel link menüsü (inline butonlar + HTML linkler)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANELS_PY="${REMOTE_DIR}/scripts/lib/telegram-panels.py"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[telegram-menu] $*"; }
notify_enabled || { log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"; exit 1; }
[[ -f "$PANELS_PY" ]] || { log "HATA: telegram-panels.py yok"; exit 1; }
if [[ -z "${TAILSCALE_PANEL_URL:-}" ]] && [[ -f /var/lib/pi-gateway/tailscale-panel-url ]]; then
  TAILSCALE_PANEL_URL="$(cat /var/lib/pi-gateway/tailscale-panel-url 2>/dev/null || true)"
fi
if [[ -z "${TAILSCALE_PANEL_URL:-}" ]] && command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_PANEL_URL="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.')
print(f'https://{d}' if d else '')
" 2>/dev/null || true)"
fi
export TAILSCALE_PANEL_URL LAN_DOMAIN PI_STATIC_IP PANEL_PROTOCOL ENABLE_TLS
MARKUP="$(python3 "$PANELS_PY" keyboard all)"
REPLY="$(python3 "$PANELS_PY" reply_keyboard)"
TEXT="$(python3 "$PANELS_PY" text all)"
curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=${TEXT}" \
  --data-urlencode "reply_markup=${MARKUP}" \
  -d "disable_web_page_preview=true" >/dev/null
# Kalici alt klavye ayri mesaj (inline + reply birlikte Telegram'da karisabilir)
curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=⌨️ <b>Hizli erisim</b> — alttaki butonlar her zaman burada. /menu = yenile." \
  --data-urlencode "reply_markup=${REPLY}" \
  -d "disable_web_page_preview=true" >/dev/null
log "Menü gönderildi"
