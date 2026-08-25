#!/usr/bin/env bash
# AdGuard DNS rewrite'lari API ile uygular (container yaml migrate sonrasi kaybolmasin)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/adguard-api.sh"
PI_STATIC_IP="${PI_STATIC_IP:-}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
[[ -n "$PI_STATIC_IP" ]] || { echo "[adguard-rewrites] PI_STATIC_IP bos"; exit 1; }
[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[adguard-rewrites] AGH_ADMIN_PASSWORD bos"; exit 1; }
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
log() { echo "[adguard-rewrites] $*"; }
agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" || {
  log "AdGuard login basarisiz"
  exit 1
}
rewrite_exists() {
  local domain="$1" answer="$2"
  curl -fsS -b "$COOKIE" "${BASE}/control/rewrite/list" | python3 -c "
import json, sys
domain, answer = sys.argv[1], sys.argv[2]
for row in json.load(sys.stdin):
    if row.get('domain') == domain and row.get('answer') == answer:
        sys.exit(0)
sys.exit(1)
" "$domain" "$answer"
}
add_rewrite() {
  local domain="$1" answer="$2"
  if rewrite_exists "$domain" "$answer"; then
    log "mevcut: ${domain} -> ${answer}"
    return 0
  fi
  curl -fsS -b "$COOKIE" -X POST "${BASE}/control/rewrite/add" \
    -H 'Content-Type: application/json' \
    -d "{\"domain\":\"${domain}\",\"answer\":\"${answer}\"}" >/dev/null
  log "eklendi: ${domain} -> ${answer}"
}
delete_rewrite() {
  local domain="$1"
  local answer="${2:-}"
  local payload
  if [[ -n "$answer" ]]; then
    payload="{\"domain\":\"${domain}\",\"answer\":\"${answer}\"}"
  else
    # answer bilinmiyorsa listedeki kaydi bul
    answer="$(curl -fsS -b "$COOKIE" "${BASE}/control/rewrite/list" | python3 -c "
import json, sys
domain = sys.argv[1]
for row in json.load(sys.stdin):
    if row.get('domain') == domain:
        print(row.get('answer') or '')
        sys.exit(0)
sys.exit(1)
" "$domain" 2>/dev/null || true)"
    [[ -n "$answer" ]] || { log "yok (silme): ${domain}"; return 0; }
    payload="{\"domain\":\"${domain}\",\"answer\":\"${answer}\"}"
  fi
  curl -fsS -b "$COOKIE" -X POST "${BASE}/control/rewrite/delete" \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null || true
  log "silindi: ${domain}"
}
verify_rewrites() {
  local expected="$1"
  local count
  count="$(curl -fsS -b "$COOKIE" "${BASE}/control/rewrite/list" | python3 -c "
import json, sys
print(len(json.load(sys.stdin)))
")"
  if [[ "$count" -lt "$expected" ]]; then
    log "HATA: beklenen en az ${expected} rewrite, bulunan ${count}"
    exit 1
  fi
}
# REMOVED: git sync (forgejo/syncthing)
OBSOLETE=(git sync)
for sub in "${OBSOLETE[@]}"; do
  delete_rewrite "${sub}.${LAN_DOMAIN}"
done
DOMAINS=(gateway dns status panel n8n logs devices grafana)
for sub in "${DOMAINS[@]}"; do
  add_rewrite "${sub}.${LAN_DOMAIN}" "$PI_STATIC_IP"
done
verify_rewrites "${#DOMAINS[@]}"
log "Tamamlandi (${#DOMAINS[@]} rewrite dogrulandi)"
