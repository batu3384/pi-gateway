#!/usr/bin/env bash
# Docker/SSD/AdGuard duserse otomatik kurtarma
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-batu}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-watchdog"

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"

STACK_AUTO_RECOVER="${STACK_AUTO_RECOVER:-true}"

log() {
  logger -t "$LOG_TAG" "$*"
  echo "[stack-watchdog] $*"
}

PROBLEMS=()

if needs_ssd_storage && ! mountpoint -q /mnt/ssd 2>/dev/null && ! storage_degraded; then
  PROBLEMS+=("ssd-unmounted")
fi

if storage_degraded; then
  PROBLEMS+=("storage-degraded")
fi

if ! root_rw_ok; then
  PROBLEMS+=("root-readonly")
fi

if ! systemctl is-active --quiet docker 2>/dev/null; then
  PROBLEMS+=("docker-inactive")
fi

if ! stack_core_ok; then
  PROBLEMS+=("stack-core-down")
fi

if [[ ${#PROBLEMS[@]} -eq 0 ]] && stack_gateway_ok && root_rw_ok; then
  exit 0
fi

[[ ${#PROBLEMS[@]} -eq 0 ]] && PROBLEMS+=("gateway-unreachable")

log "Sorun: ${PROBLEMS[*]}"

if [[ "$STACK_AUTO_RECOVER" != "true" ]]; then
  exit 1
fi

if recover_service_running; then
  log "recover-ro calisiyor — bekleniyor"
  if wait_for_recover_service; then
    if stack_fully_healthy && root_rw_ok; then
      log "recover-ro tamamlandi — stack saglikli"
      exit 0
    fi
  else
    log "recover-ro timeout"
    exit 1
  fi
fi

if stack_recover_suppressed; then
  log "Kurtarma beklemede (cooldown/boot grace)"
  exit 0
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
