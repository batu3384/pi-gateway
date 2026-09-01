#!/usr/bin/env bash
# SSD yazilim kurtarma sonrasi: docker net + restic + izinler + backup.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[repair-post-ssd] HATA: .env" >&2; exit 1; }
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
log() { echo "[repair-post-ssd] $*"; }

if ! ssd_mount_healthy; then
  log "HATA: SSD mount sagliksiz — once ssd-health/hotplug"
  exit 1
fi

REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/repair-docker-network-store.sh" \
  || log "WARN: docker network repair"
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/fix-config-perms.sh" 2>/dev/null \
  || log "WARN: config perms"

if [[ "${ENABLE_RESTIC:-true}" == "true" ]]; then
  REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/restic-repair.sh" \
    || log "WARN: restic repair"
  if REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/restic-backup.sh"; then
    log "restic backup OK"
  else
    log "WARN: restic backup"
  fi
fi

if [[ -d "$REMOTE_DIR/compose" ]]; then
  (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env up -d crowdsec) 2>/dev/null \
    || log "WARN: crowdsec up"
fi
# shellcheck source=../lib/reset-gateway-units.sh
source "$SCRIPT_DIR/../lib/reset-gateway-units.sh"
reset_pi_gateway_failed_units 2>/dev/null || true
log "Tamamlandi"
