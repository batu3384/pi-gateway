#!/usr/bin/env bash
# Docker/SSD/AdGuard duserse otomatik kurtarma
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-pi}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="pi-gateway-watchdog"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[stack-watchdog] HATA: .env dotenv parser hatasi" >&2; exit 1; }
_WATCHDOG_REMOTE_DIR="$REMOTE_DIR"
REMOTE_DIR="$_WATCHDOG_REMOTE_DIR"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
STACK_AUTO_RECOVER="${STACK_AUTO_RECOVER:-true}"
log() {
  logger -t "$LOG_TAG" "$*"
  echo "[stack-watchdog] $*"
}
PROBLEMS=()
if storage_degraded; then
  # SSD geri geldiyse idle kalma — restore tetikle
  if declare -F ssd_mount_healthy >/dev/null 2>&1 && ssd_mount_healthy; then
    log "degraded ama SSD saglikli — restore tetikleniyor"
    PROBLEMS+=("storage-degraded-ssd-ready")
  elif stack_dns_core_ok && root_rw_ok; then
    log "degraded DNS OK (adguard+unbound) — watchdog idle"
    exit 0
  else
    PROBLEMS+=("storage-degraded-dns-down")
  fi
elif needs_ssd_storage; then
  if declare -F ssd_mount_healthy >/dev/null 2>&1; then
    ssd_mount_healthy || PROBLEMS+=("ssd-unhealthy")
  elif ! mountpoint -q /mnt/ssd 2>/dev/null; then
    PROBLEMS+=("ssd-unmounted")
  fi
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
if bash "$SCRIPT_DIR/recover-stack.sh"; then
  log "Kurtarma basarili"
  # shellcheck source=../lib/notify.sh
  source "$SCRIPT_DIR/../lib/notify.sh"
  notify_stack_recovered "$(hostname -s)" "${PROBLEMS[*]}"
  exit 0
fi
log "Kurtarma basarisiz veya eksik"
exit 1
