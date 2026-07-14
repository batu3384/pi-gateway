#!/usr/bin/env bash
# Telegram: panel link menusu (inline butonlar, AI degil)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

LAN_DOMAIN="${LAN_DOMAIN:-home}"

log() { echo "[telegram-menu] $*"; }

notify_enabled || { log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"; exit 1; }

base() { printf 'http://%s.%s' "$1" "$LAN_DOMAIN"; }

MARKUP="$(python3 - "$LAN_DOMAIN" <<'PY'
import json, sys
d = sys.argv[1]
def u(host): return f"http://{host}.{d}"
kb = [
    [{"text": "Ana panel", "url": u("gateway")}],
    [
        {"text": "Kuma", "url": u("status")},
        {"text": "Loglar", "url": u("logs")},
    ],
    [
        {"text": "DNS", "url": u("dns")},
        {"text": "Git", "url": u("git")},
    ],
    [
        {"text": "Sync", "url": u("sync")},
        {"text": "n8n", "url": u("n8n")},
    ],
]
print(json.dumps({"inline_keyboard": kb}, ensure_ascii=False))
PY
)"

TEXT=$'Pi Gateway panelleri\n\nEvde veya Tailscale acikken *.home adresleri calisir.\n(Uzaktan: once Tailscale DNS ayarini tamamla.)'

curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${TEXT}" \
  --data-urlencode "reply_markup=${MARKUP}" \
  -d "disable_web_page_preview=true" >/dev/null

log "Menu gonderildi"
