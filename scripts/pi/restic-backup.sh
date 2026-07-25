#!/usr/bin/env bash
# Restic yedekleme — config + SSD veri (repo SSD uzerinde, dongusal degil)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

ENABLE_RESTIC="${ENABLE_RESTIC:-false}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
if is_ssd_root_mode; then
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
else
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"
fi
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:latest}"

log() { echo "[restic] $*"; }

[[ "$ENABLE_RESTIC" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "$RESTIC_PASSWORD" ]] || { log "HATA: RESTIC_PASSWORD .env icinde bos"; exit 1; }

if is_ssd_root_mode; then
  if ! root_on_ssd; then
    log "HATA: ssd-root modunda root SSD degil — yedek atlandi"
    exit 1
  fi
elif [[ -f /run/pi-gateway/storage-degraded ]] || ! mountpoint -q /mnt/ssd 2>/dev/null; then
  log "SSD mount yok veya degraded mod — yedek atlandi"
  exit 0
fi

DATA_ROOT="${REMOTE_DIR}/data"
if [[ -L "$DATA_ROOT" ]]; then
  DATA_ROOT="$(readlink -f "$DATA_ROOT")"
fi

REPO_HOST_PATH="$RESTIC_REPOSITORY"
mkdir -p "$REPO_HOST_PATH"

run_restic() {
  docker run --rm --network none \
    -e RESTIC_PASSWORD \
    -e RESTIC_REPOSITORY=local:/repo \
    -v "${REPO_HOST_PATH}:/repo" \
    -v "${REMOTE_DIR}/config:/backup/config:ro" \
    -v "${REMOTE_DIR}/compose:/backup/compose:ro" \
    -v "${DATA_ROOT}:/backup/data:ro" \
    "$RESTIC_IMAGE" "$@"
}

export RESTIC_PASSWORD

if ! run_restic snapshots >/dev/null 2>&1; then
  log "Repo olusturuluyor: $REPO_HOST_PATH"
  run_restic init
fi

RESTIC_BACKUP_HOST="${RESTIC_BACKUP_HOST:-${PI_HOSTNAME:-$(hostname -s)}}"
STAMP="$(date -Iseconds)"
log "Yedek basliyor ($STAMP)"
run_restic backup \
  /backup/config \
  /backup/compose \
  /backup/data \
  --tag "pi-gateway" \
  --host "$RESTIC_BACKUP_HOST" \
  --exclude '/backup/data/backups/restic' \
  --exclude '/backup/data/**/work/data' \
  --exclude '*.tmp'

run_restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
run_restic snapshots --last

# Mac backup-pull icin repo sahipligi (docker root olabilir)
sudo chown -R "${USER}:${USER}" "$REPO_HOST_PATH" 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
notify_backup_ok "$STAMP"
log "Tamamlandı"
