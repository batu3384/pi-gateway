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
# Yedek SLA — journal'da FAIL degil SLO (OnFailure/journal grep kirlenmesin)
slo_note() {
  logger -t "$LOG_TAG" "SLO $1"
  FAILURES+=("$1")
  fail=1
}
# SD sagligi (SSD kurtarma yok — pi-ssd-health.timer). SD RO recover kapali.
if ! SD_HEALTH_AUTO_RECOVER=false SSD_HEALTH_AUTO=false REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/check-sd-health.sh"; then
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
  if [[ "${ENABLE_CADDY:-true}" == "true" ]]; then
    if ! docker ps --format '{{.Names}}' | grep -q '^caddy$'; then
      note_fail "container caddy down"
    fi
    if ! stack_gateway_ok; then
      note_fail "gateway-http"
    fi
  fi
  if is_ssd_root_mode; then
    root_on_ssd || note_fail "root-still-on-sd-mmcblk"
    [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]] || note_fail "data-native-missing"
  elif [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
    if [[ ! -L "${REMOTE_DIR}/data" ]] || [[ "$(readlink -f "${REMOTE_DIR}/data")" != "/mnt/ssd/pi-gateway-data" ]]; then
      if declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy; then
        note_fail "data-ssd-symlink-broken"
      else
        logger -t "$LOG_TAG" "WARN data symlink (SSD yok — pi-ssd-health.timer sahip)"
      fi
    fi
    if declare -F ssd_mount_healthy >/dev/null 2>&1; then
      ssd_mount_healthy || logger -t "$LOG_TAG" "WARN ssd-unhealthy (pi-ssd-health.timer sahip)"
    elif ! mountpoint -q /mnt/ssd 2>/dev/null; then
      logger -t "$LOG_TAG" "WARN ssd-unmounted (pi-ssd-health.timer sahip)"
    fi
  fi
  optional_down() {
    local name="$1"
    docker ps --format '{{.Names}}' | grep -q "^${name}$" || note_fail "optional-${name}-down"
  }
  [[ "${ENABLE_N8N:-true}" == "true" ]] && optional_down n8n
  [[ "${ENABLE_NETALERTX:-true}" == "true" ]] && optional_down netalertx
  [[ "${ENABLE_DOZZLE:-true}" == "true" ]] && optional_down dozzle
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && optional_down prometheus
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && optional_down grafana
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && optional_down node-exporter
fi
if ! dig +time=2 +tries=1 @127.0.0.1 -p "${UNBOUND_PORT}" cloudflare.com A >/dev/null 2>&1; then
  note_fail "unbound:${UNBOUND_PORT}"
fi
if ! grep -q 'forward-tls-upstream: yes' "${REMOTE_DIR}/config/unbound/unbound.conf" 2>/dev/null; then
  note_fail "unbound-dot-conf"
fi
# bind-mount: up -d process reload etmez; cache'li dig yaniltir. Restart AdGuard'i dusurur (depends_on).
unbound_conf_stale() {
  local conf="${REMOTE_DIR}/config/unbound/unbound.conf"
  local started_rfc started_epoch conf_mtime
  [[ -f "$conf" ]] || return 1
  docker inspect unbound >/dev/null 2>&1 || return 1
  started_rfc="$(docker inspect -f '{{.State.StartedAt}}' unbound 2>/dev/null || true)"
  [[ -n "$started_rfc" ]] || return 1
  started_epoch="$(date -d "$started_rfc" +%s 2>/dev/null || true)"
  [[ -n "$started_epoch" ]] || return 1
  conf_mtime="$(stat -c %Y "$conf" 2>/dev/null || true)"
  [[ -n "$conf_mtime" ]] || return 1
  (( conf_mtime > started_epoch + 15 ))
}
unbound_conf_stale && note_fail "unbound-stale-conf"
adguard_dns_ok() {
  local aaaa
  dig +time=2 +tries=1 @"${PI_STATIC_IP}" cloudflare.com A >/dev/null 2>&1 \
    && dig +time=2 +tries=1 @"${PI_STATIC_IP}" doubleclick.net A 2>/dev/null | grep -Eq '0\.0\.0\.0|127\.0\.0\.0|NXDOMAIN' \
    || return 1
  aaaa="$(dig +time=2 +tries=1 +short @"${PI_STATIC_IP}" doubleclick.net AAAA 2>/dev/null || true)"
  aaaa="${aaaa%%$'\n'*}"
  [[ -z "$aaaa" || "$aaaa" == "::" || "$aaaa" == "::1" ]]
}
if ! adguard_dns_ok; then
  if [[ "${ADGUARD_AUTO_HEAL:-true}" == "true" ]]; then
    logger -t "$LOG_TAG" "adguard drift — auto-heal (light)"
    if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/ensure-adguard-blocking.sh" --fix-light; then
      logger -t "$LOG_TAG" "WARN adguard auto-heal (light) basarisiz"
    fi
  fi
fi
if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" cloudflare.com A >/dev/null 2>&1; then
  note_fail "adguard:53"
fi
if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" doubleclick.net A 2>/dev/null | grep -Eq '0\.0\.0\.0|127\.0\.0\.0|NXDOMAIN'; then
  note_fail "adguard-block-test"
else
  _aaaa="$(dig +time=2 +tries=1 +short @"${PI_STATIC_IP}" doubleclick.net AAAA 2>/dev/null || true)"
  _aaaa="${_aaaa%%$'\n'*}"
  if [[ -n "$_aaaa" && "$_aaaa" != "::" && "$_aaaa" != "::1" ]]; then
    note_fail "adguard-block-aaaa"
  fi
  unset _aaaa
fi
if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" "gateway.${LAN_DOMAIN}" A +short 2>/dev/null | grep -qx "${PI_STATIC_IP}"; then
  note_fail "adguard-rewrite-gateway.${LAN_DOMAIN}"
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
    [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] || {
      if [[ "${ADGUARD_AUTO_HEAL:-true}" == "true" ]]; then
        logger -t "$LOG_TAG" "adguard-filter-rules-low — auto-heal (filters)"
        if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/apply-adguard-filters.sh"; then
          logger -t "$LOG_TAG" "WARN adguard filter auto-heal basarisiz"
        fi
        rules="$(curl -fsS -b "$COOKIE" "${BASE}/control/filtering/status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum((f.get('rules_count') or 0) for f in d.get('filters',[])))
" 2>/dev/null || echo 0)"
      fi
      [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] || note_fail "adguard-filter-rules-low(${rules:-0})"
    }
    [[ "${rewrites:-0}" -ge "${ADGUARD_MIN_REWRITES:-8}" ]] || note_fail "adguard-rewrites-low(${rewrites:-0})"
    [[ "$dns_ok" == "1" ]] || {
      if [[ "${ADGUARD_AUTO_HEAL:-true}" == "true" ]]; then
        logger -t "$LOG_TAG" "adguard-dns-config-drift — auto-heal"
        if ! REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/apply-adguard-dns.sh"; then
          logger -t "$LOG_TAG" "WARN adguard dns auto-heal basarisiz"
        fi
        dns_ok="$(agh_dns_info "$BASE" "$COOKIE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
upstream = d.get('upstream_dns') or []
udp_ok = any(u.startswith('udp://127.0.0.1:') for u in upstream)
ptr_ok = d.get('use_private_ptr_resolvers') is False
ttl_ok = d.get('blocked_response_ttl') == int('${ADGUARD_BLOCKED_TTL:-60}')
print('1' if udp_ok and ptr_ok and ttl_ok else '0')
" 2>/dev/null || echo 0)"
      fi
      [[ "$dns_ok" == "1" ]] || note_fail "adguard-dns-config-drift"
    }
  else
    note_fail "adguard-api-login"
  fi
  rm -f "$COOKIE"
fi
# Offsite backup SLA (SSD restic alone ≠ 3-2-1). Marker: make backup-pull
# Degraded: data disk yok — SLA fail systemd spam olmasin
if storage_degraded; then
  logger -t "$LOG_TAG" "WARN offsite/drill SLA atlandi (storage-degraded)"
elif [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  max_age="${OFFSITE_BACKUP_MAX_AGE_DAYS:-7}"
  marker="/var/lib/pi-gateway/last-offsite-backup"
  if [[ "$max_age" != "0" ]]; then
    if [[ ! -f "$marker" ]]; then
      if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
        logger -t "$LOG_TAG" "WARN offsite-backup-missing WEAK_BACKUP_OK=yes"
      else
        slo_note "offsite-backup-missing"
      fi
    else
      age_days="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$marker'))//86400))")"
      if (( age_days > max_age )); then
        if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
          logger -t "$LOG_TAG" "WARN offsite-backup-stale(${age_days}d) WEAK_BACKUP_OK=yes"
        else
          slo_note "offsite-backup-stale(${age_days}d)"
        fi
      fi
    fi
  fi
fi
# Backup restore drill SLA (Mac: make backup-restore-drill)
drill_max="${BACKUP_DRILL_MAX_AGE_DAYS:-30}"
drill_marker="/var/lib/pi-gateway/last-backup-restore-drill"
if [[ "$drill_max" != "0" ]] && [[ "${ENABLE_RESTIC:-true}" == "true" ]] && ! storage_degraded; then
  if [[ ! -f "$drill_marker" ]]; then
    if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
      logger -t "$LOG_TAG" "WARN backup-restore-drill-missing WEAK_BACKUP_OK=yes"
    else
      slo_note "backup-restore-drill-missing"
    fi
  else
    drill_age="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$drill_marker'))//86400))")"
    if (( drill_age > drill_max )); then
      if [[ "${WEAK_BACKUP_OK:-}" == "yes" ]]; then
        logger -t "$LOG_TAG" "WARN backup-restore-drill-stale(${drill_age}d) WEAK_BACKUP_OK=yes"
      else
        slo_note "backup-restore-drill-stale(${drill_age}d)"
      fi
    fi
  fi
fi
# Hermes bülten SLO (07/19/23 last_run > 26h) — journal SLO, systemd FAIL değil
_run_hermes_py() {
  local kind="$1" out ec=0
  shift
  out="$("$@" 2>&1)" || ec=$?
  if (( ec != 0 )); then
    logger -t "$LOG_TAG" "WARN ${kind} fail(${ec}): ${out:-exit}"
    return 0
  fi
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -n "$line" ]] || continue
    if [[ "$kind" == *slo ]]; then
      slo_note "$line"
    else
      logger -t "$LOG_TAG" "$line"
    fi
  done <<< "$out"
}
_jobs_json="${HERMES_HOME:-$HOME/.hermes}/cron/jobs.json"
if [[ -f "$_jobs_json" ]]; then
  _run_hermes_py bulletin-slo python3 "$SCRIPT_DIR/../lib/bulletin-slo.py" "$_jobs_json"
fi
_hermes_db="${HERMES_HOME:-$HOME/.hermes}/state.db"
_hygiene_py="$SCRIPT_DIR/../lib/hermes-session-hygiene.py"
# 2 dk timer: şişman/idle Telegram oturumunu DB'de kapat (gateway restart yok, #54878)
if [[ -f "$_hermes_db" && -f "$_hygiene_py" ]]; then
  _idle_sec=$(( ${HERMES_SESSION_IDLE_MIN:-720} * 60 ))
  _run_hermes_py hermes-session-hygiene python3 "$_hygiene_py" --db "$_hermes_db" --idle-seconds "$_idle_sec"
fi
if [[ -f "$_hermes_db" ]]; then
  _run_hermes_py hermes-token-slo python3 "$SCRIPT_DIR/../lib/hermes-token-slo.py" "$_hermes_db"
fi
_reap_sh="$SCRIPT_DIR/../lib/reap-dead-docker-scopes.sh"
if [[ -f "$_reap_sh" ]]; then
  # shellcheck source=../lib/reap-dead-docker-scopes.sh
  source "$_reap_sh"
  _reap_out="$(reap_dead_docker_scopes 2>&1)" || true
  [[ -n "${_reap_out}" ]] && logger -t "$LOG_TAG" "$_reap_out"
fi
# SSD varken DNS-only fail'leri ayır (cascade: container/gateway/ssd symlink)
health_is_dns_only_fail() {
  local f="$1"
  case "$f" in
    unbound:*|unbound-dot-conf|unbound-stale-conf|container\ unbound\ down|adguard-block-test|adguard-block-aaaa|adguard-rewrite-*|adguard-dns-config-drift|adguard-filter-rules-low|adguard-rewrites-low)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
health_is_slo_fail() {
  local f="$1"
  case "$f" in
    offsite-*|backup-restore-drill*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}
# Opsiyonel + yedek SLA: journal FAIL; systemd Failed / OnFailure yalnizca cekirdek fail.
exit_code=0
if [[ "$sd_fail" -eq 1 ]]; then
  # check-sd-health.sh notify_* gonderdi — OnFailure ile tekrar spam etme
  logger -t "$LOG_TAG" "SD fail — check-sd-health bildirdi (systemd OnFailure atlanir)"
elif [[ ${#FAILURES[@]} -gt 0 ]]; then
  exit_code=0
  for f in "${FAILURES[@]}"; do
    case "$f" in
      optional-*|offsite-*|backup-restore-drill*|bulletin-*|hermes-session-*) ;;
      *) exit_code=1; break ;;
    esac
  done
elif [[ "$fail" -ne 0 ]]; then
  exit_code=1
fi
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
host="$(hostname -s)"
if [[ "$sd_fail" -eq 1 ]]; then
  logger -t "$LOG_TAG" "SD fail — notify check-sd-health"
elif [[ ${#FAILURES[@]} -eq 0 ]]; then
  logger -t "$LOG_TAG" "OK dns stack healthy"
  # Çekirdek DNS: OnFailure (notify_health_systemd_*) — health-dns çift bubble yok
  notify_optional_recovered || true
  notify_slo_backup_ok || true
else
  details="${FAILURES[*]}"
  has_ssd=0
  has_core=0
  has_optional=0
  has_slo=0
  for f in "${FAILURES[@]}"; do
    case "$f" in
      ssd-unmounted|ssd-unhealthy|storage-degraded*|data-ssd-symlink*|data-native-missing)
        has_ssd=1
        ;;
      optional-*)
        has_optional=1
        ;;
      offsite-*|backup-restore-drill*)
        has_slo=1
        ;;
      bulletin-*|hermes-session-*)
        ;;
      *)
        has_core=1
        ;;
    esac
  done
  if [[ "$has_ssd" -eq 1 ]]; then
    notify_ssd_degraded "$host" "$details"
  elif [[ "$has_core" -eq 1 ]]; then
    logger -t "$LOG_TAG" "core fail — Telegram OnFailure (health-dns yok)"
  elif [[ "$has_optional" -eq 1 ]]; then
    notify_optional_warn "$host" "$details"
  else
    logger -t "$LOG_TAG" "OK dns stack healthy"
    notify_optional_recovered || true
  fi
  if [[ "$has_slo" -eq 1 ]]; then
    slo_details=()
    for f in "${FAILURES[@]}"; do
      health_is_slo_fail "$f" && slo_details+=("$f")
    done
    notify_slo_backup "$host" "${slo_details[*]}"
  else
    notify_slo_backup_ok || true
  fi
fi
if [[ "$exit_code" -eq 0 ]]; then
  notify_health_systemd_ok || true
  # shellcheck source=../lib/reset-gateway-units.sh
  source "$SCRIPT_DIR/../lib/reset-gateway-units.sh"
  reset_pi_gateway_failed_units
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
_export="${SCRIPT_DIR}/export-gateway-state.sh"
[[ -x "$_export" ]] || _export="${REMOTE_DIR}/scripts/pi/export-gateway-state.sh"
if [[ -x "$_export" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$_export" >/dev/null 2>&1 \
    || logger -t "$LOG_TAG" "WARN export-gateway-state failed"
fi
_card="${REMOTE_DIR}/scripts/pi/telegram-status-card.sh"
if [[ -x "$_card" ]]; then
  PI_GATEWAY_HEALTH_OK="$([[ "$exit_code" -eq 0 ]] && echo 1 || echo 0)" \
    REMOTE_DIR="$REMOTE_DIR" bash "$_card" >/dev/null 2>&1 \
    || logger -t "$LOG_TAG" "WARN telegram-status-card failed"
fi
if [[ -x "$SCRIPT_DIR/push-slo-heartbeat.sh" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/push-slo-heartbeat.sh" >/dev/null 2>&1 || true
fi
# Boot downtime hesabı — her tick (fail olsa da canlılık)
notify_touch_alive || true
if (( exit_code != 0 )); then
  mkdir -p /run/pi-gateway 2>/dev/null || true
  {
    printf 'exit_code=%s\n' "$exit_code"
    (( sd_fail )) && printf 'sd_fail=1\n'
    ((${#FAILURES[@]})) && printf 'failures=%s\n' "${FAILURES[*]}"
  } > /run/pi-gateway/health-last-exit.txt 2>/dev/null || true
fi
exit "$exit_code"
