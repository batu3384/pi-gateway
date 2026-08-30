#!/usr/bin/env bash
# AdGuard filtre seti — idempotent (yalnizca fark uygular)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
# shellcheck source=../lib/adguard-api.sh
source "$SCRIPT_DIR/../lib/adguard-api.sh"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASSWORD="${AGH_ADMIN_PASSWORD:-}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
ADGUARD_FILTER_PROFILE="${ADGUARD_FILTER_PROFILE:-balanced}"
BASE="http://127.0.0.1:${ADGUARD_WEB_PORT}"
FILTERS_PY="${SCRIPT_DIR}/../lib/adguard-filters.py"
[[ -f "$FILTERS_PY" ]] || FILTERS_PY="${REMOTE_DIR}/scripts/lib/adguard-filters.py"
LOCK_FILE="${ADGUARD_FILTER_LOCK_FILE:-/run/pi-gateway/adguard-filters.lock}"
LOCK_WAIT_SEC="${ADGUARD_FILTER_LOCK_WAIT_SEC:-120}"
API_READY_WAIT_SEC="${ADGUARD_FILTER_API_READY_WAIT_SEC:-120}"
IN_PROGRESS_FILE="${ADGUARD_FILTER_IN_PROGRESS_FILE:-/run/pi-gateway/adguard-filters.in_progress}"

[[ -n "$AGH_ADMIN_PASSWORD" ]] || { echo "[adguard-filters] AGH_ADMIN_PASSWORD bos"; exit 1; }
[[ -f "$FILTERS_PY" ]] || { echo "[adguard-filters] HATA: $FILTERS_PY yok" >&2; exit 1; }
[[ "$API_READY_WAIT_SEC" =~ ^[0-9]+$ ]] || {
  echo "[adguard-filters] HATA: ADGUARD_FILTER_API_READY_WAIT_SEC sayi olmali" >&2
  exit 1
}

if [[ "${1:-}" == "--self-check" ]]; then
  exec python3 "$FILTERS_PY" --self-check
fi

log() { echo "[adguard-filters] $*"; }

COOKIE="$(mktemp)"
FILTER_LOCK_FD=""
cleanup() {
  rm -f "$COOKIE"
  if [[ -n "${FILTER_LOCK_FD:-}" ]]; then
    flock -u "$FILTER_LOCK_FD" 2>/dev/null || true
  fi
  runtime_rm "$IN_PROGRESS_FILE" 2>/dev/null || true
}
trap cleanup EXIT

agh_login "$BASE" "$COOKIE" "$AGH_ADMIN_USER" "$AGH_ADMIN_PASSWORD" \
  || { log "AdGuard login basarisiz"; exit 1; }

filtering_api_ready() {
  local deadline=$((SECONDS + API_READY_WAIT_SEC))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 5 -b "$COOKIE" \
      "${BASE}/control/filtering/status" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}
filtering_api_ready || {
  log "HATA: AdGuard filtering API hazir degil (${API_READY_WAIT_SEC}s)" >&2
  exit 1
}

# ponytail: TIF Full ~2.1M rules. Ceiling ~400MiB Available; upgrade: ADGUARD_FILTER_PROFILE=balanced.
if [[ "$ADGUARD_FILTER_PROFILE" == "aggressive" ]]; then
  _avail_kb="$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "${_avail_kb:-0}" -gt 0 && "${_avail_kb}" -lt 409600 ]]; then
    log "WARN MemAvailable ${_avail_kb}kB — aggressive -> balanced (TIF Full OOM riski)"
    ADGUARD_FILTER_PROFILE=balanced
  fi
  unset _avail_kb
fi

ensure_runtime_dir
touch "$LOCK_FILE" 2>/dev/null || sudo touch "$LOCK_FILE"
chmod 664 "$LOCK_FILE" 2>/dev/null || sudo chmod 664 "$LOCK_FILE" 2>/dev/null || true
exec {FILTER_LOCK_FD}>>"$LOCK_FILE"
flock -w "$LOCK_WAIT_SEC" "$FILTER_LOCK_FD" || {
  log "HATA: baska filtre apply calisiyor (lock timeout ${LOCK_WAIT_SEC}s)" >&2
  exit 1
}
runtime_write "$IN_PROGRESS_FILE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export BASE COOKIE REMOTE_DIR ADGUARD_FILTER_PROFILE
if python3 "$FILTERS_PY"; then
  rc=0
else
  rc=$?
fi

if [[ "$rc" -eq 0 && -x "$SCRIPT_DIR/apply-adguard-rewrites.sh" ]]; then
  bash "$SCRIPT_DIR/apply-adguard-rewrites.sh"
elif [[ "$rc" -ne 0 ]]; then
  log "WARN filter apply basarisiz — rewrites atlandi"
fi
[[ "$rc" -eq 0 ]] && log "Tamamlandi"
exit "$rc"
