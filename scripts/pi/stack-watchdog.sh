#!/usr/bin/env bash
# Docker/SSD/AdGuard duserse otomatik kurtarma
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-batu}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-watchdog"

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

STACK_AUTO_RECOVER="${STACK_AUTO_RECOVER:-true}"

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[stack-watchdog] $*"
}

PROBLEMS=()

if needs_ssd_storage && ! mountpoint -q /mnt/ssd 2>/dev/null; then
  PROBLEMS+=("ssd-unmounted")
fi

if ! systemctl is-active --quiet docker 2>/dev/null; then
  PROBLEMS+=("docker-inactive")
fi

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'adguard'; then
  PROBLEMS+=("adguard-down")
fi

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'unbound'; then
  PROBLEMS+=("unbound-down")
fi

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'caddy'; then
  PROBLEMS+=("caddy-down")
fi

if [[ ${#PROBLEMS[@]} -eq 0 ]] && stack_gateway_ok; then
  exit 0
fi

[[ ${#PROBLEMS[@]} -eq 0 ]] && PROBLEMS+=("gateway-unreachable")

log "Sorun: ${PROBLEMS[*]}"

if [[ "$STACK_AUTO_RECOVER" != "true" ]]; then
  exit 1
fi

if recover_service_running; then
  log "recover-ro su an calisiyor"
  exit 1
fi

if trigger_stack_recover "$REMOTE_DIR"; then
  log "Kurtarma basarili"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_stack_recovered "$(hostname -s)" "${PROBLEMS[*]}"
  exit 0
fi

log "Kurtarma basarisiz veya eksik"
exit 1
