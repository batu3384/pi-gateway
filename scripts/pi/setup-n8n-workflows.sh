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

# n8n CLI Pi'de yavas — sadece secret degisince import et
n8n_cli() {
  timeout 120 docker exec n8n n8n "$@" 2>/dev/null
}

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

secret_hash() {
  printf '%s' "${N8N_WEBHOOK_SECRET:-}" | sha256sum | awk '{print $1}'
}

case "${N8N_WEBHOOK_SECRET:-}" in
  ""|CHANGE_ME*) log "HATA: N8N_WEBHOOK_SECRET ayarla"; exit 1 ;;
esac

mkdir -p "$(dirname "$SECRET_MARKER")"
stored_hash="$(cat "$SECRET_MARKER" 2>/dev/null || true)"
if [[ "$(secret_hash)" == "$stored_hash" ]]; then
  log "Webhook secret degismedi — workflow import atlandi"
  exit 0
fi

render_workflow() {
  local src="$1" dst="$2"
  sed \
    -e "s|__LAN_DOMAIN__|${LAN_DOMAIN}|g" \
    -e "s|__DISK_WARN_PCT__|${DISK_WARN_PCT}|g" \
    -e "s|__N8N_WEBHOOK_SECRET__|${N8N_WEBHOOK_SECRET}|g" \
    "$src" >"$dst"
}

import_workflow() {
  local name="$1" file="$2"
  local tmp remote="/tmp/pi-gateway-wf-$$-${RANDOM}.json"

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

  if n8n_cli import:workflow --input="$remote"; then
    log "Import OK: $name"
  else
    log "UYARI: import basarisiz — $name (https://n8n.${LAN_DOMAIN})"
  fi
  docker exec n8n rm -f "$remote" 2>/dev/null || true
}

set +e
log "Webhook secret degisti — workflow import"
import_workflow "Pi Gateway — Uptime Kuma Alert" "${N8N_DIR}/uptime-kuma-alert.workflow.json"
import_workflow "Pi Gateway — Forgejo Push" "${N8N_DIR}/forgejo-push.workflow.json"
secret_hash >"$SECRET_MARKER" 2>/dev/null || true
set -e

log "Tamamlandi — https://n8n.${LAN_DOMAIN}"
log "Not: Eski workflow kopyalari n8n UI'dan silinebilir; disk-alert artik kullanilmiyor"
