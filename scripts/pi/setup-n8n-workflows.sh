#!/usr/bin/env bash
# n8n workflow import + aktif et (Uptime Kuma, disk, Forgejo)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
N8N_DIR="${REMOTE_DIR}/config/n8n"
N8N_PORT="${N8N_PORT:-5678}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"

log() { echo "[n8n-workflows] $*"; }

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

[[ "${ENABLE_N8N:-true}" == "true" ]] || { log "n8n kapali"; exit 0; }
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || {
  log "Telegram eksik — atlandi"
  exit 0
}
docker ps --format '{{.Names}}' | grep -q '^n8n$' || { log "n8n container yok"; exit 0; }

if ! curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
  log "n8n hazir degil — 30sn bekleniyor..."
  for _ in 1 2 3 4 5 6; do
    sleep 5
    curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1 && break
  done
fi
if ! curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
  log "n8n hazir degil"
  exit 0
fi

render_workflow() {
  local src="$1" dst="$2"
  sed \
    -e "s|__LAN_DOMAIN__|${LAN_DOMAIN}|g" \
    -e "s|__DISK_WARN_PCT__|${DISK_WARN_PCT}|g" \
    "$src" >"$dst"
}

workflow_id_by_name() {
  local name="$1"
  docker exec n8n n8n list:workflow --output=json 2>/dev/null | python3 -c "
import json, sys
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
rows = data if isinstance(data, list) else data.get('data', [])
for w in rows:
    if w.get('name') == name:
        print(w.get('id', ''))
        break
" "$name" 2>/dev/null || true
}

import_workflow() {
  local name="$1" file="$2"
  local existing_id tmp remote="/tmp/pi-gateway-wf-$$.json"

  existing_id="$(workflow_id_by_name "$name")"
  if [[ -n "$existing_id" ]]; then
    log "Zaten var: $name ($existing_id)"
    docker exec n8n n8n publish:workflow --id="$existing_id" 2>/dev/null || true
    return 0
  fi

  [[ -f "$file" ]] || { log "Dosya yok: $file"; return 0; }
  tmp="$(mktemp)"
  render_workflow "$file" "$tmp"
  python3 - "$tmp" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    wf = json.load(f)
with open(path, "w") as f:
    json.dump([wf], f)
PY
  docker cp "$tmp" "n8n:${remote}"
  rm -f "$tmp"

  if docker exec n8n n8n import:workflow --input="$remote" 2>/dev/null; then
    existing_id="$(workflow_id_by_name "$name")"
    if [[ -n "$existing_id" ]]; then
      docker exec n8n n8n publish:workflow --id="$existing_id" 2>/dev/null || true
      log "Aktif: $name ($existing_id)"
    fi
  else
    log "UYARI: import basarisiz — $name (owner hesabi: https://n8n.${LAN_DOMAIN})"
  fi
  docker exec n8n rm -f "$remote" 2>/dev/null || true
}

import_workflow "Pi Gateway — Uptime Kuma Alert" "${N8N_DIR}/uptime-kuma-alert.workflow.json"
import_workflow "Pi Gateway — Disk Uyarisi" "${N8N_DIR}/disk-alert.workflow.json"
import_workflow "Pi Gateway — Forgejo Push" "${N8N_DIR}/forgejo-push.workflow.json"

log "n8n yeniden baslatiliyor (workflow yayini icin)..."
cd "${REMOTE_DIR}/compose"
docker compose --profile n8n restart n8n >/dev/null 2>&1 || true
sleep 8

log "Tamamlandi — https://n8n.${LAN_DOMAIN}"
