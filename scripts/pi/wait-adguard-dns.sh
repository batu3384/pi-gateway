#!/usr/bin/env bash
# AdGuard DNS hazir olana kadar bekler (port 53 + filtre yuklenmesi)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
source "$SCRIPT_DIR/../lib/adguard-api.sh"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
PI_STATIC_IP="${PI_STATIC_IP:-127.0.0.1}"
MIN_FILTER_RULES="${ADGUARD_MIN_FILTER_RULES:-100000}"
MAX_WAIT_SEC="${ADGUARD_BOOT_WAIT_SEC:-180}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
COOKIE="$(mktemp)"
trap 'rm -f "$COOKIE"' EXIT
log() { echo "[wait-adguard] $*"; }
api_rules() {
  curl -fsS -b "$COOKIE" "${BASE}/control/filtering/status" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum((f.get('rules_count') or 0) for f in d.get('filters',[])))
" 2>/dev/null || echo 0
}
if [[ -n "$AGH_ADMIN_PASSWORD" ]]; then
  agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" 5 || {
    log "HATA: AdGuard API login basarisiz (filtre durumu okunamaz)"
    exit 1
  }
fi
deadline=$((SECONDS + MAX_WAIT_SEC))
while (( SECONDS < deadline )); do
  if dig +time=1 +tries=1 @"${PI_STATIC_IP}" cloudflare.com A >/dev/null 2>&1; then
    rules="$(api_rules)"
    if [[ "${rules:-0}" -ge "${MIN_FILTER_RULES}" ]]; then
      log "DNS hazir (kurallar=${rules})"
      exit 0
    fi
    log "DNS acik; filtre=${rules:-0}/${MIN_FILTER_RULES} bekleniyor..."
  else
    log "DNS port 53 bekleniyor..."
  fi
  sleep 3
done
log "HATA: AdGuard DNS ${MAX_WAIT_SEC}s icinde hazir olmadi"
exit 1
