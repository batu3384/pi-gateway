#!/usr/bin/env bash
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
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
sd_fail=0
note_fail() {
  logger -t "$LOG_TAG" "FAIL $1"
  FAILURES+=("$1")
  fail=1
}
# SD sagligi (kurtarma yok — asagida recover-stack.sh)
# SSD gozcu: timer'da kurtarsin (SSD_HEALTH_AUTO=true); SD RO recover kapali
if ! SD_HEALTH_AUTO_RECOVER=false SSD_HEALTH_AUTO=true REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/check-sd-health.sh"; then
  fail=1
  sd_fail=1
fi
if [[ "$STACK_AUTO_RECOVER" == "true" ]] && {
  storage_restore_pending || ! stack_fully_healthy || ! root_rw_ok
}; then
  if stack_recover_suppressed; then
    logger -t "$LOG_TAG" "stack recover atlandi (cooldown/boot grace)"
  else
    logger -t "$LOG_TAG" "stack/root auto-recover tetikleniyor"
    if ! bash "$SCRIPT_DIR/recover-stack.sh"; then
      note_fail "stack-recover-failed"
    fi
  fi
fi
if ! docker ps --format '{{.Names}}' | grep -q '^unbound$'; then
  note_fail "container unbound down"
fi
if ! docker ps --format '{{.Names}}' | grep -q '^adguard$'; then
  note_fail "container adguard down"
fi
if storage_degraded; then
  logger -t "$LOG_TAG" "storage-degraded: core DNS modu (caddy/panel opsiyonel)"
  [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]] || note_fail "storage-degraded-data-missing"
else
  if ! docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
    note_fail "container caddy down"
  fi
  if ! stack_gateway_ok; then
    note_fail "gateway-http"
  fi
  if is_ssd_root_mode; then
    root_on_ssd || note_fail "root-still-on-sd-mmcblk"
    [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]] || note_fail "data-native-missing"
  elif [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
    if [[ ! -L "${REMOTE_DIR}/data" ]] || [[ "$(readlink -f "${REMOTE_DIR}/data")" != "/mnt/ssd/pi-gateway-data" ]]; then
      note_fail "data-ssd-symlink-broken"
    fi
    if declare -F ssd_mount_healthy >/dev/null 2>&1; then
      ssd_mount_healthy || note_fail "ssd-unhealthy"
    elif ! mountpoint -q /mnt/ssd 2>/dev/null; then
      note_fail "ssd-unmounted"
    fi
  fi
  optional_down() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -q "^${name}$" || note_fail "optional-${name}-down"
  }
  [[ "${ENABLE_FORGEJO:-true}" == "true" ]] && optional_down forgejo
  [[ "${ENABLE_N8N:-true}" == "true" ]] && optional_down n8n
  [[ "${ENABLE_NETALERTX:-true}" == "true" ]] && optional_down netalertx
  [[ "${ENABLE_SYNCTHING:-true}" == "true" ]] && optional_down syncthing
  [[ "${ENABLE_REDIS:-false}" == "true" ]] && optional_down redis
  [[ "${ENABLE_DOZZLE:-true}" == "true" ]] && optional_down dozzle
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
# SSD varken DNS-only fail'leri ayır (cascade: container/gateway/ssd symlink)
health_is_dns_only_fail() {
  local f="$1"
  case "$f" in
    unbound:*|container\ unbound\ down|adguard-block-test|adguard-rewrite-*|adguard-dns-config-drift|adguard-filter-rules-low|adguard-rewrites-low)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
if [[ "$fail" -eq 0 ]]; then
  logger -t "$LOG_TAG" "OK dns stack healthy"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_dns_recovered "$(hostname -s)" || true
  notify_optional_recovered || true
else
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  host="$(hostname -s)"
  details="${FAILURES[*]}"
  has_ssd=0
  has_core=0
  has_optional=0
  for f in "${FAILURES[@]}"; do
    case "$f" in
      ssd-unmounted|storage-degraded*|data-ssd-symlink*|data-native-missing)
        has_ssd=1
        ;;
      optional-*)
        has_optional=1
        ;;
      *)
        has_core=1
        ;;
    esac
  done
  if [[ "$has_ssd" -eq 1 ]]; then
    notify_ssd_degraded "$host" "$details"
    dns_only=()
    for f in "${FAILURES[@]}"; do
      health_is_dns_only_fail "$f" && dns_only+=("$f")
    done
    if [[ ${#dns_only[@]} -gt 0 ]]; then
      notify_dns_fail "$host" "${dns_only[*]}"
    fi
  elif [[ "$has_core" -eq 1 ]]; then
    notify_dns_fail "$host" "$details"
  elif [[ "$has_optional" -eq 1 ]]; then
    # Opsiyonel panel; "DNS sağlığı" diye bağırma
    notify_optional_warn "$host" "$details"
  fi
fi
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
DISK_PRUNE_PCT="${DISK_PRUNE_PCT:-65}"
for mount in / /mnt/ssd; do
  if [[ -d "$mount" ]]; then
    usage="$(df "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')"
    if [[ -n "${usage:-}" ]] && (( usage >= DISK_WARN_PCT )); then
      # shellcheck source=../lib/notify.sh
      source "$SCRIPT_DIR/../lib/notify.sh"
      notify_disk_warn "$mount" "$usage"
      logger -t "$LOG_TAG" "WARN disk ${mount} at ${usage}%"
    fi
    if [[ "$mount" == "/" ]] && [[ -n "${usage:-}" ]] && (( usage >= DISK_PRUNE_PCT )); then
      REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/prune-sd-space.sh" || \
        logger -t "$LOG_TAG" "WARN sd-prune failed"
    fi
  fi
done
# Offsite backup SLA (SSD restic alone ≠ 3-2-1). Marker: make backup-pull
if [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  max_age="${OFFSITE_BACKUP_MAX_AGE_DAYS:-7}"
  marker="/var/lib/pi-gateway/last-offsite-backup"
  if [[ "$max_age" != "0" ]]; then
    if [[ ! -f "$marker" ]]; then
      if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
        logger -t "$LOG_TAG" "WARN offsite-backup-missing WEAK_BACKUP_OK=yes"
      else
        note_fail "offsite-backup-missing"
      fi
    else
      age_days="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$marker'))//86400))")"
      if (( age_days > max_age )); then
        if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
          logger -t "$LOG_TAG" "WARN offsite-backup-stale(${age_days}d) WEAK_BACKUP_OK=yes"
        else
          note_fail "offsite-backup-stale(${age_days}d)"
        fi
      fi
    fi
  fi
fi
# Backup restore drill SLA (Mac: make backup-restore-drill)
drill_max="${BACKUP_DRILL_MAX_AGE_DAYS:-30}"
drill_marker="/var/lib/pi-gateway/last-backup-restore-drill"
if [[ "$drill_max" != "0" ]] && [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  if [[ ! -f "$drill_marker" ]]; then
    if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
      logger -t "$LOG_TAG" "WARN backup-restore-drill-missing WEAK_BACKUP_OK=yes"
    else
      note_fail "backup-restore-drill-missing"
    fi
  else
    drill_age="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$drill_marker'))//86400))")"
    if (( drill_age > drill_max )); then
      if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
        logger -t "$LOG_TAG" "WARN backup-restore-drill-stale(${drill_age}d) WEAK_BACKUP_OK=yes"
      else
        note_fail "backup-restore-drill-stale(${drill_age}d)"
      fi
    fi
  fi
fi
if [[ -x "$SCRIPT_DIR/export-gateway-state.sh" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/export-gateway-state.sh" >/dev/null 2>&1 \
    || logger -t "$LOG_TAG" "WARN export-gateway-state failed"
fi
if [[ -x "$SCRIPT_DIR/push-slo-heartbeat.sh" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/push-slo-heartbeat.sh" >/dev/null 2>&1 || true
fi
# Opsiyonel-only: journal'da FAIL kalsın; systemd "Failed" spam olmasın.
# SD veya çekirdek/SSD fail → exit 1. Offsite SLA da fail-exit (WEAK_BACKUP_OK escape).
exit_code=0
if [[ "$sd_fail" -eq 1 ]]; then
  exit_code=1
elif [[ ${#FAILURES[@]} -gt 0 ]]; then
  exit_code=0
  for f in "${FAILURES[@]}"; do
    case "$f" in
      optional-*) ;;
      *) exit_code=1; break ;;
    esac
  done
elif [[ "$fail" -ne 0 ]]; then
  exit_code=1
fi
exit "$exit_code"
