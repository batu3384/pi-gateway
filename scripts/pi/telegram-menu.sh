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

TAILSCALE_PANEL_URL="${TAILSCALE_PANEL_URL:-}"
if [[ -z "$TAILSCALE_PANEL_URL" ]] && command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_PANEL_URL="$(tailscale status --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin).get('Self',{}).get('DNSName','').rstrip('.')
print(f'https://{d}' if d else '')
" 2>/dev/null || true)"
fi
export TAILSCALE_PANEL_URL

MARKUP="$(python3 - "$LAN_DOMAIN" "$PANEL_PROTOCOL" "$TAILSCALE_PANEL_URL" <<'PY'
import json, sys

domain = sys.argv[1]
proto = sys.argv[2]
remote_base = (sys.argv[3] or "").rstrip("/")

def url(host: str) -> str:
    return f"{proto}://{host}.{domain}"

def remote(path: str = "") -> str:
    if not remote_base:
        return url("gateway")
    return f"{remote_base}{path}"

keyboard = []
if remote_base:
    keyboard.append([{"text": "🌐 Uzaktan Ana Panel", "url": remote("/")}])
    keyboard.append([
        {"text": "Uptime", "url": remote("/p/status")},
        {"text": "Loglar", "url": remote("/p/logs")},
    ])
    keyboard.append([
        {"text": "AdGuard", "url": remote("/p/dns")},
        {"text": "Cihazlar", "url": remote("/p/devices")},
    ])
    keyboard.append([
        {"text": "Forgejo", "url": remote("/p/git")},
        {"text": "n8n", "url": remote("/p/n8n")},
    ])
keyboard.append([{"text": "🏠 Ev: Ana Panel", "url": url("gateway")}])
keyboard.append([
    {"text": "Ev: Kuma", "url": url("status")},
    {"text": "Ev: DNS", "url": url("dns")},
])
keyboard.append([{"text": "Ev: Cihazlar", "url": url("devices")}])
print(json.dumps({"inline_keyboard": keyboard}, ensure_ascii=False))
PY
)"

TEXT="$(cat <<EOF
<b>Pi Gateway</b> — Kontrol Panelleri

<b>Ev agi:</b> *.${LAN_DOMAIN} (Wi‑Fi + Pi DNS)
<b>Uzaktan:</b> Tailscale acikken ustteki 🌐 butonlar
${TAILSCALE_PANEL_URL:+(<code>${TAILSCALE_PANEL_URL}</code>)}

<b>IP yedek:</b> ${PANEL_PROTOCOL}://${PI_IP}

<i>Telefonda *.home acilmiyorsa Tailscale + ust satirdaki uzaktan linkleri kullan.</i>
EOF
)"

curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=${TEXT}" \
  --data-urlencode "reply_markup=${MARKUP}" \
  -d "disable_web_page_preview=true" >/dev/null

log "Menü gönderildi"
