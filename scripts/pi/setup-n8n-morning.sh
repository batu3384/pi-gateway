#!/usr/bin/env bash
# n8n: sabah ozeti workflow (Telegram, 08:00 Europe/Istanbul)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

N8N_PORT="${N8N_PORT:-5678}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
WORKFLOW_FILE="${REMOTE_DIR}/config/n8n/morning-summary.workflow.json"

log() { echo "[n8n-morning] $*"; }

[[ "${ENABLE_N8N:-true}" == "true" ]] || { log "n8n kapali"; exit 0; }
notify_enabled() { [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; }
notify_enabled || { log "Telegram eksik — atlandi"; exit 0; }
docker ps --format '{{.Names}}' | grep -q '^n8n$' || { log "n8n container yok"; exit 0; }
[[ -f "$WORKFLOW_FILE" ]] || { log "Workflow dosyasi yok: $WORKFLOW_FILE"; exit 0; }

# n8n owner hesabi yoksa import atlanir (ilk kurulumda tarayicidan owner olustur)
if ! curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
  log "n8n hazir degil"
  exit 0
fi

WF_NAME="Pi Gateway Sabah Ozeti"
WF_ID="$(docker exec n8n n8n list:workflow --output=json 2>/dev/null | python3 -c "
import json,sys
name=sys.argv[1]
try:
    data=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for w in data if isinstance(data,list) else data.get('data',[]):
    if w.get('name')==name:
        print(w.get('id',''))
        break
" "$WF_NAME" 2>/dev/null || true)"

if [[ -n "$WF_ID" ]]; then
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
  NEW_ID="$(docker exec n8n n8n list:workflow --output=json 2>/dev/null | python3 -c "
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
for w in data if isinstance(data,list) else data.get('data',[]):
    if w.get('name')==name:
        print(w.get('id',''))
        break
" "$WF_NAME" 2>/dev/null || true)"
  if [[ -n "$NEW_ID" ]]; then
    docker exec n8n n8n update:workflow --id="$NEW_ID" --active=true 2>/dev/null || true
    log "Workflow aktif: $WF_NAME"
  fi
else
  log "UYARI: n8n owner hesabi gerekli — http://n8n.${LAN_DOMAIN} uzerinden ilk kurulumu tamamla"
fi

log "Tamamlandi"
