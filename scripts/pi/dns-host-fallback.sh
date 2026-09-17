#!/usr/bin/env bash
# AGH rewrite yokken :53 asla bos birakma. stop yalniz AGH cevapliyorsa veya --force.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="pi-gateway-dns-fallback.service"
log() { echo "[dns-host-fallback] $*"; }

if [[ -f "${SCRIPT_DIR}/../lib/env-file.sh" ]]; then
  # shellcheck source=../lib/env-file.sh
  source "${SCRIPT_DIR}/../lib/env-file.sh"
  read_remote_dotenv || true
fi
if [[ -f "${SCRIPT_DIR}/../lib/ssd-alive.sh" ]]; then
  # shellcheck source=../lib/ssd-alive.sh
  source "${SCRIPT_DIR}/../lib/ssd-alive.sh"
fi

if [[ "${DNS_HOST_FALLBACK:-true}" != "true" ]]; then
  log "DNS_HOST_FALLBACK=false — atlandi"
  exit 0
fi

run_sys() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  else
    sudo "$@"
  fi
}

agh_rewrite_ok() {
  local ip="${PI_STATIC_IP:-127.0.0.1}"
  local domain="${LAN_DOMAIN:-home}"
  timeout 2 dig +time=1 +tries=1 +short @"$ip" "gateway.${domain}" A 2>/dev/null \
    | grep -qx "$ip"
}

# Overlay SSD'de: mount ölü/degraded iken AGH hâlâ cevaplıyor olabilir — fallback'i kesme.
docker_overlay_at_risk() {
  [[ "${ENABLE_DOCKER_SSD:-false}" == "true" ]] || return 1
  [[ -f "${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}" ]] && return 0
  if declare -F ssd_mount_healthy >/dev/null 2>&1; then
    ssd_mount_healthy && return 1
    return 0
  fi
  mountpoint -q /mnt/ssd 2>/dev/null || return 0
  return 1
}

cmd_stop() {
  local force="${1:-0}"
  if [[ "$force" != "1" ]] && ! agh_rewrite_ok; then
    log "stop atlandi — AGH rewrite yok (:53 koru)"
    return 0
  fi
  run_sys systemctl stop "$UNIT" 2>/dev/null || true
  run_sys systemctl reset-failed "$UNIT" 2>/dev/null || true
}

cmd_start() {
  local wait_die="${1:-0}"
  local i
  if [[ "$wait_die" == "1" ]]; then
    for i in $(seq 1 "${DNS_FALLBACK_WAIT_DIE_SEC:-12}"); do
      agh_rewrite_ok || break
      sleep 1
    done
  fi
  # rewrite OK olsa bile unit'i durdurma — proxy :53 mesgulse bind-wait (USB arm).
  run_sys systemctl reset-failed "$UNIT" 2>/dev/null || true
  if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
    return 0
  fi
  if ! run_sys systemctl start "$UNIT"; then
    log "WARN unit start basarisiz"
    return 1
  fi
  if agh_rewrite_ok; then
    log "armed (AGH :53; bind-wait)"
  else
    log "basladi (AGH yok)"
  fi
}

cmd_ensure() {
  if agh_rewrite_ok && ! docker_overlay_at_risk; then
    cmd_stop 1
    return 0
  fi
  cmd_start
}

action="${1:-ensure}"
force=0
wait_die=0
[[ "${2:-}" == "--force" ]] && force=1
[[ "${2:-}" == "--wait-die" ]] && wait_die=1
case "$action" in
  start) cmd_start "$wait_die" ;;
  stop) cmd_stop "$force" ;;
  ensure) cmd_ensure ;;
  --self-check)
    grep -q 'stop atlandi' "$0" || exit 1
    grep -q -- '--force' "$0" || exit 1
    grep -q -- '--wait-die' "$0" || exit 1
    grep -q 'docker_overlay_at_risk' "$0" || exit 1
    grep -q 'armed (AGH' "$0" || exit 1
    grep -q 'dns-dot-proxy.py' "$0" || exit 1
    [[ -f "${SCRIPT_DIR}/../lib/dns-dot-proxy.py" ]] || exit 1
    python3 "${SCRIPT_DIR}/../lib/dns-dot-proxy.py" --self-check
    ;;
  *)
    log "HATA: kullanim: start [--wait-die]|stop [--force]|ensure|--self-check"
    exit 2
    ;;
esac
