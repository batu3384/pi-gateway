#!/usr/bin/env bash
# n8n: sabah ozeti workflow (Telegram, 08:00 Europe/Istanbul)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

N8N_DIR="${REMOTE_DIR}/config/n8n"
N8N_PORT="${N8N_PORT:-5678}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
WF_NAME="Pi Gateway Sabah Ozeti"

log() { echo "[n8n-morning] $*"; }

n8n_workflow_id() {
  local name="$1"
  docker exec n8n n8n list:workflow 2>/dev/null | python3 -c "
import sys
name = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line or '|' not in line:
        continue
    wf_id, wf_name = line.split('|', 1)
    if wf_name == name:
        print(wf_id)
        break
" "$name" 2>/dev/null || true
}

resolve_workflow_file() {
  local f
  for f in \
    "${N8N_DIR}/morning-summary.workflow.json" \
    "${N8N_DIR}/archive/morning-summary.workflow.json"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

[[ "${ENABLE_N8N:-true}" == "true" ]] || { log "n8n kapali"; exit 0; }
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || { log "Telegram eksik — atlandi"; exit 0; }
docker ps --format '{{.Names}}' | grep -q '^n8n$' || { log "n8n container yok"; exit 0; }

WORKFLOW_FILE="$(resolve_workflow_file)" || { log "Workflow dosyasi yok"; exit 0; }

if ! curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
  log "n8n hazir degil"
  exit 0
fi

WF_ID="$(n8n_workflow_id "$WF_NAME")"
if [[ -n "$WF_ID" ]]; then
  docker exec n8n n8n publish:workflow --id="$WF_ID" 2>/dev/null \
    || docker exec n8n n8n update:workflow --id="$WF_ID" --active=true 2>/dev/null || true
  log "Workflow zaten var: $WF_NAME ($WF_ID)"
  exit 0
fi

TMP="/tmp/pi-gateway-morning-$$.json"
sed \
  -e "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g" \
  -e "s|__TELEGRAM_CHAT_ID__|${TELEGRAM_CHAT_ID}|g" \
  -e "s|__LAN_DOMAIN__|${LAN_DOMAIN}|g" \
  "$WORKFLOW_FILE" > "$TMP"

docker cp "$TMP" n8n:/tmp/morning-summary.json
rm -f "$TMP"

if docker exec n8n n8n import:workflow --input=/tmp/morning-summary.json 2>/dev/null; then
  NEW_ID="$(n8n_workflow_id "$WF_NAME")"
  if [[ -n "$NEW_ID" ]]; then
    docker exec n8n n8n publish:workflow --id="$NEW_ID" 2>/dev/null \
      || docker exec n8n n8n update:workflow --id="$NEW_ID" --active=true 2>/dev/null || true
    docker restart n8n >/dev/null 2>&1 || true
    log "Workflow aktif: $WF_NAME"
  fi
else
  log "UYARI: n8n owner hesabi gerekli — http://n8n.${LAN_DOMAIN} uzerinden ilk kurulumu tamamla"
fi

log "Tamamlandi"
