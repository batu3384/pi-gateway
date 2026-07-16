#!/usr/bin/env bash
# Sabah özeti — Telegram (n8n owner gerektirmez)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"

log() { echo "[morning-summary] $*"; }

notify_enabled || { log "Telegram eksik"; exit 0; }

host="$(hostname -s)"
gateway="$(panel_url gateway)"
disk="$(df -h / /mnt/ssd 2>/dev/null | tail -n +2 || df -h / | tail -n +2)"
containers="$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null | head -16 || echo 'docker yok')"
load="$(uptime 2>/dev/null | sed 's/.*load average/load:/')"
running="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
healthy="$(docker ps --filter health=healthy --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"

body="$(cat <<EOF
<b>${host}</b> — günlük durum

<b>Paneller:</b> ${gateway}
<b>Konteyner:</b> ${running} çalışıyor, ${healthy} healthy

<b>Disk</b>
<pre>${disk}</pre>

<b>Servisler</b>
<pre>${containers}</pre>

<b>${load}</b>
EOF
)"

curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=☀️ Pi Gateway — Sabah özeti

${body}" \
  -d "disable_web_page_preview=true" >/dev/null 2>&1 || true

log "Gönderildi"
