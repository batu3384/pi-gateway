#!/usr/bin/env bash
# Pi 4B + full stack: aggressive AdGuard profile → DNS tail latency.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
ENV="${REMOTE_DIR}/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "[ensure-dns-perf] $*"; }

[[ -f "$ENV" ]] || { log "HATA: .env yok"; exit 1; }
# shellcheck source=../lib/env-file.sh
source "${SCRIPT_DIR}/../lib/env-file.sh"
read_remote_dotenv || { log "HATA: .env parse"; exit 1; }

set_kv() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENV"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$ENV"
  else
    echo "${k}=${v}" >> "$ENV"
  fi
}

for pair in \
  "ADGUARD_BLOCKED_TTL:300" \
  "ADGUARD_AUTO_HEAL:false" \
  "ADGUARD_DNS_AUTO_HEAL:true" \
  "GATEWAY_VIDEO_DNS_PROBE:false" \
  "ADGUARD_COVERAGE_AUDIT_ENABLED:false"; do
  k="${pair%%:*}"
  v="${pair#*:}"
  cur="$(grep -m1 "^${k}=" "$ENV" 2>/dev/null | cut -d= -f2- || true)"
  [[ "$cur" == "$v" ]] || set_kv "$k" "$v"
done

profile="${ADGUARD_FILTER_PROFILE:-balanced}"
if [[ "$profile" == "aggressive" ]]; then
  if [[ "${ADGUARD_ALLOW_AGGRESSIVE:-false}" == "true" ]]; then
    log "aggressive profil korunuyor (ADGUARD_ALLOW_AGGRESSIVE=true)"
    exit 0
  fi
  log "WARN: aggressive → balanced (DNS performansi)"
  set_kv ADGUARD_FILTER_PROFILE balanced
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/apply-adguard-filters.sh"
  log "profil=balanced (uygulandi)"
  exit 0
fi
log "profil=${ADGUARD_FILTER_PROFILE:-balanced} (env guncel)"
