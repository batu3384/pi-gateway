#!/usr/bin/env bash
# Forgejo -> n8n push webhook
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

FORGEJO_PORT="${FORGEJO_PORT:-3002}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-batu}"
FORGEJO_REPO_NAME="${FORGEJO_REPO_NAME:-pi-gateway}"
N8N_WEBHOOK_URL="${N8N_FORGEJO_WEBHOOK_URL:-}"
if [[ -z "$N8N_WEBHOOK_URL" ]]; then
  secret="${N8N_WEBHOOK_SECRET:-}"
  case "$secret" in
    ""|CHANGE_ME*) echo "[forgejo-webhook] HATA: N8N_WEBHOOK_SECRET gerekli"; exit 1 ;;
  esac
  N8N_WEBHOOK_URL="http://n8n:5678/webhook/forgejo-push-${secret}"
fi
TOKEN_FILE="${REMOTE_DIR}/data/forgejo/.n8n-api-token"
TOKEN_NAME="pi-gateway-n8n"

log() { echo "[forgejo-webhook] $*"; }

[[ "${ENABLE_FORGEJO:-true}" == "true" ]] || exit 0
[[ "${ENABLE_N8N:-true}" == "true" ]] || exit 0
docker ps --format '{{.Names}}' | grep -q '^forgejo$' || { log "HATA: forgejo yok"; exit 1; }
docker ps --format '{{.Names}}' | grep -q '^n8n$' || { log "HATA: n8n yok"; exit 1; }

api_token() {
  if [[ -f "$TOKEN_FILE" ]]; then
    cat "$TOKEN_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$TOKEN_FILE")"
  local token
  token="$(docker exec -u git forgejo forgejo admin user generate-access-token \
    --username "$FORGEJO_ADMIN_USER" \
    --token-name "$TOKEN_NAME" \
    --scopes "read:repository,write:repository" \
    --raw 2>/dev/null || true)"
  [[ -n "$token" ]] || return 1
  printf '%s' "$token" >"$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  printf '%s' "$token"
}

TOKEN="$(api_token || true)"
[[ -n "$TOKEN" ]] || { log "HATA: Forgejo API token alinamadi"; exit 1; }

API="http://127.0.0.1:${FORGEJO_PORT}/api/v1"
AUTH=(-H "Authorization: token ${TOKEN}")

if ! curl -fsS "${AUTH[@]}" "${API}/version" >/dev/null 2>&1; then
  log "Forgejo API hazir degil"
  exit 0
fi

repo_ok="$(curl -fsS "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
  "${API}/repos/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME}" 2>/dev/null || echo 000)"
if [[ "$repo_ok" != "200" ]]; then
  log "Repo yok: ${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME} — once Forgejo'da olustur"
  exit 0
fi

hooks="$(curl -fsS "${AUTH[@]}" \
  "${API}/repos/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME}/hooks" 2>/dev/null || echo '[]')"

if echo "$hooks" | python3 -c "
import json, sys
url = sys.argv[1]
hooks = json.load(sys.stdin)
sys.exit(0 if any((h.get('config') or {}).get('url') == url for h in hooks) else 1)
" "$N8N_WEBHOOK_URL"; then
  log "Webhook zaten var: $N8N_WEBHOOK_URL"
  exit 0
fi

payload="$(python3 - <<PY
import json
print(json.dumps({
  "type": "gitea",
  "active": True,
  "events": ["push"],
  "config": {
    "url": "${N8N_WEBHOOK_URL}",
    "content_type": "json"
  }
}))
PY
)"

code="$(curl -fsS "${AUTH[@]}" -o /dev/null -w '%{http_code}' \
  -X POST "${API}/repos/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME}/hooks" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>/dev/null || echo 000)"

if [[ "$code" == "201" ]]; then
  log "Webhook eklendi: ${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME} -> $N8N_WEBHOOK_URL"
else
  log "HATA: webhook eklenemedi (HTTP $code)"
  exit 1
fi
