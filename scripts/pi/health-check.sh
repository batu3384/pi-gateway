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
# shellcheck source=../lib/unbound-dnssec.sh
source "$SCRIPT_DIR/../lib/unbound-dnssec.sh"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
# systemd ExecStart = /usr/local/lib copy. AGH apply lived stale/missing there.
# Home git wins when present; privileged copy is fallback.
_pi_home_script() {
  local name="$1"
  local home="${REMOTE_DIR}/scripts/pi/${name}"
  if [[ -f "$home" ]]; then
    printf '%s\n' "$home"
  else
    printf '%s\n' "${SCRIPT_DIR}/${name}"
  fi
}
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
  optional_prometheus_ok() {
    docker ps --format '{{.Names}}' | grep -q '^prometheus$' && return 0
    if [[ "${PROMETHEUS_AUTO_HEAL:-true}" == "true" ]]; then
      local repair="${SCRIPT_DIR}/repair-prometheus-tsdb.sh"
      local plogs
      if [[ -x "$repair" ]]; then
        plogs="$(docker logs prometheus 2>&1 | tail -50 || true)"
        if echo "$plogs" | grep -qE 'invalid checksum|opening storage failed' \
          || { echo "$plogs" | grep -q 'WAL truncation' \
            && echo "$plogs" | grep -q 'compaction failed'; }; then
          logger -t "$LOG_TAG" "prometheus TSDB — auto-heal"
          if REMOTE_DIR="$REMOTE_DIR" NOTIFY_REPAIR=1 bash "$repair"; then
            docker ps --format '{{.Names}}' | grep -q '^prometheus$' && return 0
          fi
        fi
      fi
    fi
    note_fail "optional-prometheus-down"
  }
  [[ "${ENABLE_N8N:-true}" == "true" ]] && optional_down n8n
  [[ "${ENABLE_NETALERTX:-true}" == "true" ]] && optional_down netalertx
  [[ "${ENABLE_DOZZLE:-true}" == "true" ]] && optional_down dozzle
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && optional_prometheus_ok
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && optional_down grafana
  [[ "${ENABLE_MONITORING:-true}" == "true" ]] && optional_down node-exporter
fi
if ! dig +time=2 +tries=1 @127.0.0.1 -p "${UNBOUND_PORT}" cloudflare.com A >/dev/null 2>&1; then
  note_fail "unbound:${UNBOUND_PORT}"
elif ! unbound_dnssec_ad_ok "${UNBOUND_PORT}"; then
  note_fail "unbound-dnssec-ad"
fi
if ! grep -q 'forward-tls-upstream: yes' "${REMOTE_DIR}/config/unbound/unbound.conf" 2>/dev/null; then
  note_fail "unbound-dot-conf"
fi
# bind-mount: up -d process reload etmez; cache'li dig yaniltir. Restart AdGuard'i dusurur (depends_on).
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
  if [[ "${ADGUARD_AUTO_HEAL:-false}" == "true" ]]; then
    logger -t "$LOG_TAG" "adguard drift — auto-heal (light)"
    if ! REMOTE_DIR="$REMOTE_DIR" bash "$(_pi_home_script ensure-adguard-blocking.sh)" --fix-light; then
      logger -t "$LOG_TAG" "WARN adguard auto-heal (light) basarisiz"
    fi
  fi
fi
if ! adguard_dns_ok; then
  note_fail "adguard-dns-block"
fi
if ! dig +time=2 +tries=1 @"${PI_STATIC_IP}" "gateway.${LAN_DOMAIN}" A +short 2>/dev/null | grep -qx "${PI_STATIC_IP}"; then
  note_fail "adguard-rewrite-gateway.${LAN_DOMAIN}"
fi
if [[ -n "${AGH_ADMIN_PASSWORD:-}" ]]; then
  COOKIE="$(mktemp)"
  BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
  _filters_py="${SCRIPT_DIR}/../lib/adguard-filters.py"
  [[ -f "$_filters_py" ]] || _filters_py="${REMOTE_DIR}/scripts/lib/adguard-filters.py"
  _filter_in_progress="${ADGUARD_FILTER_IN_PROGRESS_FILE:-/run/pi-gateway/adguard-filters.in_progress}"
  if agh_login "$BASE" "$COOKIE" "${AGH_ADMIN_USER:-admin}" "$AGH_ADMIN_PASSWORD" 3; then
    filter_governance_ok=true
    if systemctl is-failed --quiet pi-gateway-adguard-filters.service 2>/dev/null; then
      logger -t "$LOG_TAG" "adguard filter service failed"
      filter_governance_ok=false
    fi
    _filter_state="${ADGUARD_FILTER_STATE_PATH:-/var/lib/pi-gateway/adguard-filter-state.json}"
    _filter_last_success="$(
      python3 - "$_filter_state" <<'PY'
import json
import sys
from datetime import datetime

try:
    value = json.loads(open(sys.argv[1], encoding="utf-8").read()).get("last_success_at")
    print(datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp())
except (OSError, TypeError, ValueError, json.JSONDecodeError):
    print("")
PY
    )"
    if [[ -n "$_filter_last_success" ]] && awk -v now="$(date +%s)" \
      -v last="$_filter_last_success" \
      -v max_age="${ADGUARD_FILTER_SCHEDULED_SLA_SEC:-93600}" \
      'BEGIN { exit !(now - last > max_age) }'; then
      logger -t "$LOG_TAG" "adguard filter scheduled SLA asildi"
      filter_governance_ok=false
    fi
    [[ -n "$_filter_last_success" ]] || filter_governance_ok=false
    unset _filter_state _filter_last_success
    if [[ -f "$_filter_in_progress" ]]; then
      logger -t "$LOG_TAG" "adguard filter apply suruyor — auto-heal atlandi"
      filter_governance_ok=false
    elif [[ -f "$_filters_py" ]]; then
      if ! REMOTE_DIR="$REMOTE_DIR" BASE="$BASE" COOKIE="$COOKIE" \
        ADGUARD_FILTER_PROFILE="${ADGUARD_FILTER_PROFILE:-balanced}" \
        python3 "$_filters_py" --governance-check; then
        filter_governance_ok=false
      fi
    fi
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
    [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] || filter_governance_ok=false
    if [[ "$filter_governance_ok" != "true" ]]; then
      if [[ "${ADGUARD_AUTO_HEAL:-true}" == "true" && ! -f "$_filter_in_progress" ]]; then
        logger -t "$LOG_TAG" "adguard-filter-governance — auto-heal (filters)"
        if ! ADGUARD_FILTER_FORCE_REFRESH=true REMOTE_DIR="$REMOTE_DIR" \
          bash "$(_pi_home_script apply-adguard-filters.sh)"; then
          logger -t "$LOG_TAG" "WARN adguard filter auto-heal basarisiz"
        fi
        if [[ -f "$_filters_py" ]] && REMOTE_DIR="$REMOTE_DIR" BASE="$BASE" COOKIE="$COOKIE" \
          ADGUARD_FILTER_PROFILE="${ADGUARD_FILTER_PROFILE:-balanced}" \
          python3 "$_filters_py" --governance-check 2>/dev/null; then
          filter_governance_ok=true
        fi
        rules="$(curl -fsS -b "$COOKIE" "${BASE}/control/filtering/status" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum((f.get('rules_count') or 0) for f in d.get('filters',[])))
" 2>/dev/null || echo 0)"
        [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] || filter_governance_ok=false
      fi
      [[ "$filter_governance_ok" == "true" ]] \
        || note_fail "adguard-filter-governance"
      [[ "${rules:-0}" -ge "${ADGUARD_MIN_FILTER_RULES:-100000}" ]] \
        || note_fail "adguard-filter-rules-low(${rules:-0})"
    fi
    [[ "${rewrites:-0}" -ge "${ADGUARD_MIN_REWRITES:-8}" ]] || note_fail "adguard-rewrites-low(${rewrites:-0})"
    [[ "$dns_ok" == "1" ]] || {
      if [[ "${ADGUARD_DNS_AUTO_HEAL:-true}" == "true" ]]; then
        logger -t "$LOG_TAG" "adguard-dns-config-drift — auto-heal (dns)"
        if ! REMOTE_DIR="$REMOTE_DIR" bash "$(_pi_home_script apply-adguard-dns.sh)"; then
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
# Cloud offsite (B2/R2) when enabled
if [[ "${RESTIC_OFFSITE_ENABLED:-false}" == "true" ]] && [[ "${ENABLE_RESTIC:-true}" == "true" ]] \
  && ! storage_degraded; then
  cloud_max="${RESTIC_OFFSITE_COPY_MAX_AGE_DAYS:-3}"
  cloud_marker="/var/lib/pi-gateway/last-restic-offsite-copy"
  if [[ "$cloud_max" != "0" ]]; then
    if [[ ! -f "$cloud_marker" ]]; then
      slo_note "restic-offsite-missing"
    else
      cloud_age="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$cloud_marker'))//86400))")"
      if (( cloud_age > cloud_max )); then
        slo_note "restic-offsite-stale(${cloud_age}d)"
      fi
    fi
  fi
fi
# Backup restore drill SLA (Mac: make backup-restore-drill)
drill_max="${BACKUP_DRILL_MAX_AGE_DAYS:-30}"
drill_marker="/var/lib/pi-gateway/last-backup-restore-drill"
drill_failure_marker="/var/lib/pi-gateway/last-backup-restore-drill-failure"
if [[ "$drill_max" != "0" ]] && [[ "${ENABLE_RESTIC:-true}" == "true" ]] && ! storage_degraded; then
  if [[ -f "$drill_failure_marker" ]] \
    && { [[ ! -f "$drill_marker" ]] || [[ "$drill_failure_marker" -nt "$drill_marker" ]]; }; then
    slo_note "backup-restore-drill-failed"
  fi
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
    case "$kind" in
      bulletin-slo|hermes-token-slo|hermes-session-hygiene)
        slo_note "${kind}-failed"
        ;;
    esac
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
    unbound:*|unbound-dot-conf|unbound-stale-conf|unbound-dnssec-ad|container\ unbound\ down|adguard-block-test|adguard-block-aaaa|adguard-rewrite-*|adguard-dns-config-drift|adguard-filter-rules-low|adguard-rewrites-low)
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
    offsite-*|restic-offsite-*|backup-restore-drill*)
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
      optional-*|offsite-*|restic-offsite-*|backup-restore-drill*|bulletin-*|hermes-session-*|hermes-token-*) ;;
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
  notify_restic_offsite_ok || true
  notify_slo_ops_ok || true
else
  details="${FAILURES[*]}"
  has_ssd=0
  has_core=0
  has_optional=0
  has_slo=0
  has_ops_slo=0
  for f in "${FAILURES[@]}"; do
    case "$f" in
      ssd-unmounted|ssd-unhealthy|storage-degraded*|data-ssd-symlink*|data-native-missing)
        has_ssd=1
        ;;
      optional-*)
        has_optional=1
        ;;
      offsite-*|restic-offsite-*|backup-restore-drill*)
        has_slo=1
        ;;
      bulletin-*|hermes-session-*|hermes-token-*)
        has_ops_slo=1
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
    _monitoring_details=()
    for f in "${FAILURES[@]}"; do
      case "$f" in
        optional-prometheus-down|optional-grafana-down|optional-node-exporter-down)
          _monitoring_details+=("$f")
          ;;
      esac
    done
    if [[ ${#_monitoring_details[@]} -gt 0 ]]; then
      notify_monitoring_stack_warn "$host" "${_monitoring_details[*]}" || true
    fi
    unset _monitoring_details
  elif [[ "$has_optional" -eq 1 ]]; then
    notify_optional_warn "$host" "$details"
  else
    logger -t "$LOG_TAG" "OK dns stack healthy"
    notify_optional_recovered || true
  fi
  if [[ "$has_slo" -eq 1 ]]; then
    slo_details=()
    cloud_stale=""
    cloud_missing=0
    for f in "${FAILURES[@]}"; do
      if health_is_slo_fail "$f"; then
        slo_details+=("$f")
        case "$f" in
          restic-offsite-stale*)
            cloud_stale="${f#restic-offsite-stale(}"
            cloud_stale="${cloud_stale%)}"
            ;;
          restic-offsite-missing)
            cloud_missing=1
            ;;
        esac
      fi
    done
    if [[ "$cloud_missing" -eq 1 ]]; then
      notify_restic_offsite_missing || true
    elif [[ -n "$cloud_stale" ]]; then
      notify_restic_offsite_stale "${cloud_stale%d}" || true
    else
      notify_restic_offsite_ok || true
    fi
    notify_slo_backup "$host" "${slo_details[*]}"
  else
    notify_slo_backup_ok || true
    notify_restic_offsite_ok || true
  fi
  if [[ "$has_ops_slo" -eq 1 ]]; then
    ops_slo_details=()
    for f in "${FAILURES[@]}"; do
      case "$f" in
        bulletin-*|hermes-session-*|hermes-token-*) ops_slo_details+=("$f") ;;
      esac
    done
    notify_slo_ops "$host" "${ops_slo_details[*]}"
  else
    notify_slo_ops_ok || true
  fi
fi
if [[ "$exit_code" -eq 0 ]]; then
  notify_health_systemd_ok || true
  if ! storage_degraded && declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy; then
    if [[ "$(cat "${NOTIFY_STATE_DIR:-/var/lib/pi-gateway/notify}/ssd-degraded.state" 2>/dev/null)" == "fail" ]]; then
      notify_ssd_restored "$(hostname -s 2>/dev/null || echo pi-gateway)" \
        "Periyodik sağlık kontrolü SSD'yi doğruladı."
    fi
  fi
  # shellcheck source=../lib/reset-gateway-units.sh
  source "$SCRIPT_DIR/../lib/reset-gateway-units.sh"
  reset_pi_gateway_failed_units
fi
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
DISK_PRUNE_PCT="${DISK_PRUNE_PCT:-65}"
INODE_WARN_PCT="${INODE_WARN_PCT:-80}"
MEM_WARN_MB="${MEM_WARN_MB:-128}"
for mount in / /mnt/ssd; do
  if [[ -d "$mount" ]]; then
    usage="$(df -P "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')"
    if [[ -n "${usage:-}" && "$usage" =~ ^[0-9]+$ ]] && (( 10#$usage >= DISK_WARN_PCT )); then
      notify_disk_warn "$mount" "${usage}%"
      logger -t "$LOG_TAG" "WARN disk ${mount} at ${usage}%"
    fi
    iusage="$(df -iP "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')"
    if [[ -n "${iusage:-}" && "$iusage" =~ ^[0-9]+$ ]] && (( 10#$iusage >= INODE_WARN_PCT )); then
      notify_disk_warn "$mount" "inode ${iusage}%" "Inode doluluk: ${mount}"
      logger -t "$LOG_TAG" "WARN inode ${mount} at ${iusage}%"
    fi
    if [[ "$mount" == "/" ]] && [[ -n "${usage:-}" && "$usage" =~ ^[0-9]+$ ]] && (( 10#$usage >= DISK_PRUNE_PCT )); then
      REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/prune-sd-space.sh" || \
        logger -t "$LOG_TAG" "WARN sd-prune failed"
    fi
  fi
done
mem_avail_mb="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)"
if [[ -n "${mem_avail_mb:-}" && "$mem_avail_mb" =~ ^[0-9]+$ ]] && (( 10#$mem_avail_mb < MEM_WARN_MB )); then
  notify_disk_warn "memory" "MemAvailable ${mem_avail_mb}MiB (esik ${MEM_WARN_MB})" "Bellek düşük"
  logger -t "$LOG_TAG" "WARN mem available ${mem_avail_mb}MiB"
fi
# Coverage is evidence, not core DNS health; warn mode keeps expected ZTE DNS2 degraded state visible.
_coverage_audit="${REMOTE_DIR}/scripts/pi/audit-dns-coverage.sh"
if [[ "${ADGUARD_COVERAGE_AUDIT_ENABLED:-false}" == "true" ]] && [[ -x "$_coverage_audit" ]]; then
  _coverage_log="$(mktemp /tmp/pi-gateway-dns-coverage.XXXXXX)"
  if ! ADGUARD_COVERAGE_AUDIT_MODE=warn REMOTE_DIR="$REMOTE_DIR" \
    bash "$_coverage_audit" >"$_coverage_log" 2>&1; then
    logger -t "$LOG_TAG" "WARN dns coverage audit failed"
  fi
  rm -f "$_coverage_log"
fi
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
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/push-slo-heartbeat.sh" >/dev/null 2>&1 \
    || logger -t "$LOG_TAG" "WARN SLO heartbeat push failed"
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
else
  rm -f /run/pi-gateway/health-last-exit.txt 2>/dev/null || true
fi
exit "$exit_code"
