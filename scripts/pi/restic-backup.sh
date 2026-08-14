#!/usr/bin/env bash
# Restic yedekleme — config + SSD veri (repo SSD uzerinde, dongusal degil)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[restic] HATA: .env dotenv parser hatasi" >&2; exit 1; }
ENABLE_RESTIC="${ENABLE_RESTIC:-true}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
if is_ssd_root_mode; then
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
else
  RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"
fi
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
RESTIC_TIMEOUT_SEC="${RESTIC_TIMEOUT_SEC:-7200}"
RESTIC_CHOWN_TIMEOUT_SEC="${RESTIC_CHOWN_TIMEOUT_SEC:-120}"
RESTIC_REINIT_MARKER="${RESTIC_REINIT_MARKER:-/var/lib/pi-gateway/restic-reinit}"
RESTIC_ALLOW_REINIT="${RESTIC_ALLOW_REINIT:-false}"
log() { echo "[restic] $*"; }
[[ "$ENABLE_RESTIC" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "$RESTIC_PASSWORD" ]] || { log "HATA: RESTIC_PASSWORD .env icinde bos"; exit 1; }
if is_ssd_root_mode; then
  if ! root_on_ssd; then
    log "HATA: ssd-root modunda root SSD degil — yedek atlandi"
    exit 1
  fi
elif [[ -f /run/pi-gateway/storage-degraded ]] || ! mountpoint -q /mnt/ssd 2>/dev/null \
  || { declare -F ssd_mount_healthy >/dev/null 2>&1 && ! ssd_mount_healthy; }; then
  log "SSD mount yok veya degraded — yedek atlandi"
  exit 0
fi
DATA_ROOT="${REMOTE_DIR}/data"
if [[ -L "$DATA_ROOT" ]]; then
  DATA_ROOT="$(readlink -f "$DATA_ROOT")"
fi
REPO_HOST_PATH="$RESTIC_REPOSITORY"
if [[ -e "$REPO_HOST_PATH" && ! -d "$REPO_HOST_PATH" ]]; then
  log "HATA: Restic repository path klasor degil: $REPO_HOST_PATH"
  exit 1
fi
REPO_WAS_PRESENT=0
if [[ -d "$REPO_HOST_PATH" ]] && find "$REPO_HOST_PATH" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  REPO_WAS_PRESENT=1
fi
mkdir -p "$REPO_HOST_PATH"
run_restic() {
  timeout "$RESTIC_TIMEOUT_SEC" docker run --rm --network none \
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
  if [[ "$REPO_WAS_PRESENT" -eq 1 ]]; then
    log "HATA: mevcut Restic repo okunamiyor — init reddedildi; repair/recovery gerekli"
    # shellcheck source=../lib/notify.sh
    source "$SCRIPT_DIR/../lib/notify.sh"
    notify_backup_fail "$(date -Iseconds)" "existing Restic repo unavailable; init refused"
    exit 1
  fi
  log "Repo olusturuluyor: $REPO_HOST_PATH"
  run_restic init
fi
RESTIC_BACKUP_HOST="${RESTIC_BACKUP_HOST:-${PI_HOSTNAME:-$(hostname -s)}}"
STAMP="$(date -Iseconds)"
log "Yedek basliyor ($STAMP)"
do_backup() {
  run_restic backup \
    /backup/config \
    /backup/compose \
    /backup/data \
    --tag "pi-gateway" \
    --host "$RESTIC_BACKUP_HOST" \
    --exclude '/backup/data/backups/restic' \
    --exclude '/backup/data/**/work/data' \
    --exclude '*.tmp'
}
REINIT_DONE=0
if ! do_backup; then
  log "WARN: backup fail — restic repair snapshots deneniyor"
  run_restic unlock 2>/dev/null || true
  run_restic repair snapshots 2>/dev/null || true
  run_restic repair index 2>/dev/null || true
  run_restic prune 2>/dev/null || true
  if ! do_backup; then
    if [[ "$RESTIC_ALLOW_REINIT" != "true" ]]; then
      log "HATA: Restic repo kurtarilamadi — otomatik reinit kapali (RESTIC_ALLOW_REINIT=true ile bilincli kurtarma)"
      # shellcheck source=../lib/notify.sh
      source "$SCRIPT_DIR/../lib/notify.sh"
      notify_backup_fail "$STAMP" "Restic repair failed; automatic reinit disabled"
      exit 1
    fi
    log "WARN: repo kurtarilamadi — yedek klasoru yeniden init (GECMIS KORUNUR: .corrupt.*)"
    bak="${REPO_HOST_PATH}.corrupt.$(date +%Y%m%d%H%M%S)"
    mv "$REPO_HOST_PATH" "$bak" 2>/dev/null || true
    mkdir -p "$REPO_HOST_PATH"
    run_restic init
    REINIT_DONE=1
    mkdir -p "$(dirname "$RESTIC_REINIT_MARKER")" 2>/dev/null \
      || sudo mkdir -p "$(dirname "$RESTIC_REINIT_MARKER")" 2>/dev/null || true
    {
      echo "ts=$STAMP"
      echo "bak=$bak"
    } | tee "$RESTIC_REINIT_MARKER" >/dev/null 2>&1 \
      || echo "ts=$STAMP" | sudo tee "$RESTIC_REINIT_MARKER" >/dev/null
    do_backup || {
      log "HATA: fresh init sonrasi backup basarisiz"
      # shellcheck source=../lib/notify.sh
      source "$SCRIPT_DIR/../lib/notify.sh"
      notify_backup_fail "$STAMP" "fresh init sonrasi backup basarisiz"
      exit 1
    }
  fi
fi
run_restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
run_restic snapshots --last
timeout "$RESTIC_CHOWN_TIMEOUT_SEC" sudo chown -R "${USER}:${USER}" "$REPO_HOST_PATH" 2>/dev/null \
  || log "WARN: chown timeout/atlandi ($RESTIC_CHOWN_TIMEOUT_SEC s)"
# shellcheck source=../lib/notify.sh
source "$SCRIPT_DIR/../lib/notify.sh"
if [[ "$REINIT_DONE" -eq 1 ]]; then
  notify_backup_fail "$STAMP" "restic repo reinit — eski snapshot'lar ${bak:-.corrupt.*}; Mac backup-pull --delete REDDEDILIR (marker)"
  log "Tamamlandi (REINIT — notify fail, exit 1)"
  exit 1
fi
notify_backup_ok "$STAMP"
log "Tamamlandi"
