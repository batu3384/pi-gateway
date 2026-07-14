#!/usr/bin/env bash
# Sabah ozeti — Telegram (n8n owner gerektirmez)
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
disk="$(df -h / /mnt/ssd 2>/dev/null | tail -n +2 || df -h / | tail -n +2)"
containers="$(docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | head -16 || echo 'docker yok')"
load="$(uptime 2>/dev/null | sed 's/.*load average/load:/')"

body="$(printf '%s\n\n%s\n\n---\n%s\n\n---\n%s' \
  "$host" "$disk" "$containers" "$load")"

# Sabah mesaji: cooldown yok (gunluk tek)
curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=$(printf '☀️ Pi Gateway — Sabah özeti\n\n%s' "$body")" \
  --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || true

log "Gonderildi"
