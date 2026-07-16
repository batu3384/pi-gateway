#!/usr/bin/env bash
# Telegram: panel link menüsü (inline butonlar)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

LAN_DOMAIN="${LAN_DOMAIN:-home}"
PI_IP="${PI_STATIC_IP:-192.168.1.112}"
PANEL_PROTOCOL="${PANEL_PROTOCOL:-$([[ "${ENABLE_TLS:-false}" == "true" ]] && echo https || echo http)}"

log() { echo "[telegram-menu] $*"; }

notify_enabled || { log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID eksik"; exit 1; }

MARKUP="$(python3 - "$LAN_DOMAIN" "$PANEL_PROTOCOL" <<'PY'
import json, sys

domain = sys.argv[1]
proto = sys.argv[2]

def url(host: str) -> str:
    return f"{proto}://{host}.{domain}"

keyboard = [
    [{"text": "Ana Panel", "url": url("gateway")}],
    [
        {"text": "Uptime Kuma", "url": url("status")},
        {"text": "Loglar", "url": url("logs")},
    ],
    [
        {"text": "AdGuard DNS", "url": url("dns")},
        {"text": "Forgejo", "url": url("git")},
    ],
    [
        {"text": "Syncthing", "url": url("sync")},
        {"text": "n8n", "url": url("n8n")},
    ],
]
print(json.dumps({"inline_keyboard": keyboard}, ensure_ascii=False))
PY
)"

TEXT="$(cat <<EOF
<b>Pi Gateway</b> — Kontrol Panelleri

Ev ağında aşağıdaki butonlardan servise gidin.
Uzaktan erişim için Tailscale + split DNS gerekir.

<b>Ana panel:</b> $(panel_url gateway)
<b>IP yedek:</b> ${PANEL_PROTOCOL}://${PI_IP}

<i>Bu bot yalnızca bildirim gönderir.</i>
EOF
)"

curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=${TEXT}" \
  --data-urlencode "reply_markup=${MARKUP}" \
  -d "disable_web_page_preview=true" >/dev/null

log "Menü gönderildi"
