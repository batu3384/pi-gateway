#!/usr/bin/env bash
# Forgejo -> n8n push webhook
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
FORGEJO_PORT="${FORGEJO_PORT:-3002}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-admin}"
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
  local token name="$TOKEN_NAME"
  token="$(docker exec -u git forgejo forgejo admin user generate-access-token \
    --username "$FORGEJO_ADMIN_USER" \
    --token-name "$name" \
    --scopes "write:user,write:repository,read:user,read:repository" \
    --raw 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    name="${TOKEN_NAME}-$(date +%s)"
    token="$(docker exec -u git forgejo forgejo admin user generate-access-token \
      --username "$FORGEJO_ADMIN_USER" \
      --token-name "$name" \
      --scopes "write:user,write:repository,read:user,read:repository" \
      --raw 2>/dev/null || true)"
  fi
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
forgejo_http_code() {
  local method="$1"
  local url="$2"
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' -X "$method" "${AUTH[@]}" "$@" "$url" 2>/dev/null || echo 000
}
ensure_repo() {
  local code
  code="$(forgejo_http_code GET "${API}/repos/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME}")"
  if [[ "$code" == "200" ]]; then
    return 0
  fi
  if [[ "$code" != "404" ]]; then
    log "HATA: repo kontrolu basarisiz (HTTP $code)"
    return 1
  fi
  log "Repo olusturuluyor: ${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME}"
  payload="$(python3 - <<PY
import json
print(json.dumps({
  "name": "${FORGEJO_REPO_NAME}",
  "private": True,
  "auto_init": True,
  "default_branch": "main",
}))
PY
)"
  code="$(forgejo_http_code POST "${API}/user/repos" \
    -H "Content-Type: application/json" \
    -d "$payload")"
  if [[ "$code" == "201" ]]; then
    log "Repo olusturuldu"
    return 0
  fi
  log "HATA: repo olusturulamadi (HTTP $code)"
  return 1
}
if ! ensure_repo; then
  log "Repo olusturulamadi — API token yenileniyor"
  rm -f "$TOKEN_FILE"
  TOKEN="$(api_token || true)"
  [[ -n "$TOKEN" ]] || { log "HATA: Forgejo API token yenilenemedi"; exit 1; }
  AUTH=(-H "Authorization: token ${TOKEN}")
  ensure_repo || exit 1
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
code="$(forgejo_http_code POST "${API}/repos/${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME}/hooks" \
  -H "Content-Type: application/json" \
  -d "$payload")"
if [[ "$code" == "201" ]]; then
  log "Webhook eklendi: ${FORGEJO_ADMIN_USER}/${FORGEJO_REPO_NAME} -> $N8N_WEBHOOK_URL"
else
  log "HATA: webhook eklenemedi (HTTP $code)"
  exit 1
fi
