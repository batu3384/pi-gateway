#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

LOG_TAG="pi-gateway-health"
PI_STATIC_IP="${PI_STATIC_IP:-127.0.0.1}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
UNBOUND_PORT="${UNBOUND_PORT:-5335}"
STACK_AUTO_RECOVER="${STACK_AUTO_RECOVER:-true}"
fail=0
FAILURES=()

note_fail() {
  logger -t "$LOG_TAG" "FAIL $1"
  FAILURES+=("$1")
  fail=1
}

# SD sagligi (kurtarma yok — asagida tek trigger_stack_recover)
if ! SD_HEALTH_AUTO_RECOVER=false REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/check-sd-health.sh"; then
  fail=1
fi

if [[ "$STACK_AUTO_RECOVER" == "true" ]] && ! stack_fully_healthy; then
  logger -t "$LOG_TAG" "stack auto-recover tetikleniyor"
  trigger_stack_recover "$REMOTE_DIR" || true
fi

if ! docker ps --format '{{.Names}}' | grep -q '^unbound$'; then
  note_fail "container unbound down"
fi

if ! docker ps --format '{{.Names}}' | grep -q '^adguard$'; then
  note_fail "container adguard down"
fi

if ! docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
  note_fail "container caddy down"
fi

if ! stack_gateway_ok; then
  note_fail "gateway-http"
fi

if [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]]; then
  if [[ ! -L "${REMOTE_DIR}/data" ]] || [[ "$(readlink -f "${REMOTE_DIR}/data")" != "/mnt/ssd/pi-gateway-data" ]]; then
    note_fail "data-ssd-symlink-broken"
  fi
fi

if ! dig +time=2 +tries=1 @127.0.0.1 -p "${UNBOUND_PORT}" cloudflare.com A >/dev/null 2>&1; then
  note_fail "unbound:${UNBOUND_PORT}"
fi

if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" cloudflare.com A >/dev/null 2>&1; then
  note_fail "adguard:53"
fi

if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" doubleclick.net A 2>/dev/null | grep -Eq '0\.0\.0\.0|127\.0\.0\.0|NXDOMAIN'; then
  note_fail "adguard-block-test"
fi

if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" "git.${LAN_DOMAIN}" A +short 2>/dev/null | grep -qx "${PI_STATIC_IP}"; then
  note_fail "adguard-rewrite-git.${LAN_DOMAIN}"
fi

if [[ -n "${AGH_ADMIN_PASSWORD:-}" ]]; then
  COOKIE="$(mktemp)"
  BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
  if agh_login "$BASE" "$COOKIE" "${AGH_ADMIN_USER:-admin}" "$AGH_ADMIN_PASSWORD" 3; then
    rules="$(curl -fsS -b "$COOKIE" "${BASE}/control/filtering/status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum((f.get('rules_count') or 0) for f in d.get('filters',[])))
" 2>/dev/null || echo 0)"
    rewrites="$(curl -fsS -b "$COOKIE" "${BASE}/control/rewrite/list" | python3 -c "
import json,sys
print(len(json.load(sys.stdin)))
" 2>/dev/null || echo 0)"
    dns_ok="$(agh_dns_info "$BASE" "$COOKIE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
upstream = d.get('upstream_dns') or []
udp_ok = any(u.startswith('udp://127.0.0.1:') for u in upstream)
ptr_ok = d.get('use_private_ptr_resolvers') is False
ttl_ok = d.get('blocked_response_ttl') == int('${ADGUARD_BLOCKED_TTL:-60}')
print('1' if udp_ok and ptr_ok and ttl_ok else '0')
" 2>/dev/null || echo 0)"
    [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] || note_fail "adguard-filter-rules-low(${rules:-0})"
    [[ "${rewrites:-0}" -ge "${ADGUARD_MIN_REWRITES:-7}" ]] || note_fail "adguard-rewrites-low(${rewrites:-0})"
    [[ "$dns_ok" == "1" ]] || note_fail "adguard-dns-config-drift"
  else
    note_fail "adguard-api-login"
  fi
  rm -f "$COOKIE"
fi

if [[ "$fail" -eq 0 ]]; then
  logger -t "$LOG_TAG" "OK dns stack healthy"
else
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_dns_fail "$(hostname -s)" "${FAILURES[*]}"
fi

DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
for mount in / /mnt/ssd; do
  if [[ -d "$mount" ]]; then
    usage="$(df "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')"
    if [[ -n "${usage:-}" ]] && (( usage >= DISK_WARN_PCT )); then
      # shellcheck source=../lib/notify.sh
      source "$SCRIPT_DIR/../lib/notify.sh"
      notify_disk_warn "$mount" "$usage"
      logger -t "$LOG_TAG" "WARN disk ${mount} at ${usage}%"
    fi
  fi
done

exit "$fail"
