#!/usr/bin/env bash
# n8n workflow import + aktif et (Uptime Kuma, Forgejo)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
N8N_DIR="${REMOTE_DIR}/config/n8n"
N8N_PORT="${N8N_PORT:-5678}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
SECRET_MARKER="${REMOTE_DIR}/data/n8n/.webhook-secret-hash"

log() { echo "[n8n-workflows] $*"; }

n8n_cli() {
  timeout 120 docker exec n8n n8n "$@" 2>/dev/null
}

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

[[ "${ENABLE_N8N:-true}" == "true" ]] || { log "n8n kapali"; exit 0; }
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || {
  log "HATA: TELEGRAM_BOT_TOKEN ve TELEGRAM_CHAT_ID gerekli"
  exit 1
}
docker ps --format '{{.Names}}' | grep -q '^n8n$' || { log "HATA: n8n container yok"; exit 1; }

if ! curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
  log "n8n hazir degil — 30sn bekleniyor..."
  for _ in 1 2 3 4 5 6; do
    sleep 5
    curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1 && break
  done
fi
if ! curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1; then
  log "HATA: n8n hazir degil"
  exit 1
fi

secret_hash() {
  printf '%s' "${N8N_WEBHOOK_SECRET:-}" | sha256sum | awk '{print $1}'
}

case "${N8N_WEBHOOK_SECRET:-}" in
  ""|CHANGE_ME*) log "HATA: N8N_WEBHOOK_SECRET ayarla"; exit 1 ;;
esac

render_workflow() {
  local src="$1" dst="$2"
  sed \
    -e "s|__LAN_DOMAIN__|${LAN_DOMAIN}|g" \
    -e "s|__DISK_WARN_PCT__|${DISK_WARN_PCT}|g" \
    -e "s|__N8N_WEBHOOK_SECRET__|${N8N_WEBHOOK_SECRET}|g" \
    "$src" >"$dst"
}

activate_workflow() {
  local name="$1"
  local id
  id="$(n8n_cli list:workflow 2>/dev/null | python3 -c "
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
" "$name" 2>/dev/null || true)"
  [[ -n "$id" ]] || { log "HATA: workflow bulunamadi — $name"; return 1; }
  if n8n_cli publish:workflow --id="$id" 2>/dev/null; then
    log "Aktif: $name (id=$id)"
    return 0
  fi
  if n8n_cli update:workflow --id="$id" --active=true 2>/dev/null; then
    log "Aktif: $name (id=$id)"
    return 0
  fi
  log "HATA: aktivasyon basarisiz — $name"
  return 1
}

import_workflow() {
  local name="$1" file="$2"
  local tmp remote="/tmp/pi-gateway-wf-$$-${RANDOM}.json"

  [[ -f "$file" ]] || { log "HATA: dosya yok — $file"; return 1; }
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

  if ! n8n_cli import:workflow --input="$remote"; then
    docker exec n8n rm -f "$remote" 2>/dev/null || true
    log "HATA: import basarisiz — $name"
    return 1
  fi
  docker exec n8n rm -f "$remote" 2>/dev/null || true
  log "Import OK: $name"
  activate_workflow "$name"
}

mkdir -p "$(dirname "$SECRET_MARKER")"
stored_hash="$(cat "$SECRET_MARKER" 2>/dev/null || true)"
needs_import=false
if [[ "$(secret_hash)" != "$stored_hash" ]]; then
  needs_import=true
  log "Webhook secret degisti — workflow import"
else
  log "Webhook secret ayni — import atlandi, aktivasyon dogrulaniyor"
fi

fail=0
needs_restart=false
if [[ "$needs_import" == "true" ]]; then
  import_workflow "Pi Gateway — Uptime Kuma Alert" "${N8N_DIR}/uptime-kuma-alert.workflow.json" || fail=1
  import_workflow "Pi Gateway — Forgejo Push" "${N8N_DIR}/forgejo-push.workflow.json" || fail=1
  if [[ "$fail" -eq 0 ]]; then
    secret_hash >"$SECRET_MARKER"
    needs_restart=true
  fi
else
  activate_workflow "Pi Gateway — Uptime Kuma Alert" || fail=1
  activate_workflow "Pi Gateway — Forgejo Push" || fail=1
  needs_restart=true
fi

if [[ "$needs_restart" == "true" ]] && [[ "$fail" -eq 0 ]]; then
  log "n8n yeniden baslatiliyor (webhook kaydi)"
  docker restart n8n >/dev/null 2>&1 || log "WARN: n8n restart basarisiz"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 5
    curl -fsS "http://127.0.0.1:${N8N_PORT}/healthz" >/dev/null 2>&1 && break
  done
fi

[[ "$fail" -eq 0 ]] || exit 1
log "Tamamlandi — https://n8n.${LAN_DOMAIN}"
