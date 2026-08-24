#!/usr/bin/env bash
# Sabah özeti — Telegram (n8n owner gerektirmez)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/notify.sh"
log() { echo "[morning-summary] $*"; }
notify_enabled || { log "Telegram eksik"; exit 0; }

host="$(hostname -s)"
gateway="$(panel_url gateway)"
disk="$(df -h / /mnt/ssd 2>/dev/null | tail -n +2 || df -h / | tail -n +2)"
containers="$(docker ps --format '{{.Names}} — {{.Status}}' 2>/dev/null | head -12 || echo 'docker yok')"
load="$(uptime 2>/dev/null | sed 's/.*load average/load:/')"
running="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
healthy="$(docker ps --filter health=healthy --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
temp=""
if command -v vcgencmd >/dev/null 2>&1; then
  temp="$(vcgencmd measure_temp 2>/dev/null | sed 's/temp=//' || true)"
fi

esc_host="$(notify_escape_html "$host")"
esc_gateway="$(notify_escape_html "$gateway")"
esc_disk="$(notify_escape_html "$disk")"
esc_containers="$(notify_escape_html "$containers")"
esc_load="$(notify_escape_html "$load")"
stack_line="${running} container, ${healthy} healthy"
[[ -n "$temp" ]] && stack_line="${stack_line}, CPU ${temp}"
esc_stack="$(notify_escape_html "$stack_line")"

body="$(cat <<EOF
<b>${esc_host}</b> — günlük durum özeti
<b>Panel:</b> ${esc_gateway}
<b>Stack:</b> ${esc_stack}

<b>Disk</b>
<pre>${esc_disk}</pre>

<b>Servisler</b>
<pre>${esc_containers}</pre>

<b>${esc_load}</b>
<i>Otomatik özet — Hermes bültenleri ayrı kanal.</i>
EOF
)"

if ! notify_send_message "📋 Pi Gateway · Sabah özeti

${body}" "HTML"; then
  log "HATA: Telegram gonderilemedi"
  exit 1
fi
log "Gönderildi"
