#!/usr/bin/env bash
# 3-2-1 doğrulama: restic check (Pi repo + opsiyonel Mac kopyası)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
LOCAL_REPO="${MAC_BACKUP_DEST:-$HOME/Backups/pi-gateway}/restic"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.17.3}"
CHECK_SUBSET="${RESTIC_CHECK_SUBSET:-5%}"
TARGET="${1:-both}"

log() { echo "[restore-check] $*"; }
die() { echo "[restore-check] HATA: $*" >&2; exit 1; }

[[ "$ENABLE_RESTIC" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "RESTIC_PASSWORD .env icinde bos"

run_check() {
  local label="$1" repo_path="$2"
  [[ -d "$repo_path" ]] || { log "SKIP $label — repo yok: $repo_path"; return 0; }
  log "check: $label ($repo_path, subset=$CHECK_SUBSET)"
  docker run --rm --network none \
    -e RESTIC_PASSWORD \
    -v "${repo_path}:/repo:ro" \
    "$RESTIC_IMAGE" -r "local:/repo" check --read-data-subset="$CHECK_SUBSET"
  log "OK: $label"
}

case "$TARGET" in
  pi)
    [[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli (target=pi)"
    RESTIC_REMOTE="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
    ssh -o ConnectTimeout=15 "$PI_USER@$PI_HOST" \
      "REMOTE_DIR='$REMOTE_DIR' RESTIC_CHECK_SUBSET='$CHECK_SUBSET' bash -s" <<'REMOTE'
set -euo pipefail
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"
[[ -d "$RESTIC_REPOSITORY" ]] || { echo "[restore-check] SKIP pi — repo yok"; exit 0; }
docker run --rm --network none \
  -e RESTIC_PASSWORD \
  -v "${RESTIC_REPOSITORY}:/repo:ro" \
  restic/restic:0.17.3 -r "local:/repo" check --read-data-subset="${RESTIC_CHECK_SUBSET:-5%}"
REMOTE
    ;;
  local)
    run_check "mac-offsite" "$LOCAL_REPO"
    ;;
  both)
    if [[ -n "$PI_HOST" ]]; then
      RESTIC_REMOTE="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
      if ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_USER@$PI_HOST" "test -d '$RESTIC_REMOTE'" 2>/dev/null; then
        ssh -o ConnectTimeout=15 "$PI_USER@$PI_HOST" \
          "REMOTE_DIR='$REMOTE_DIR' RESTIC_CHECK_SUBSET='$CHECK_SUBSET' bash -s" <<'REMOTE'
set -euo pipefail
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"
docker run --rm --network none \
  -e RESTIC_PASSWORD \
  -v "${RESTIC_REPOSITORY}:/repo:ro" \
  restic/restic:0.17.3 -r "local:/repo" check --read-data-subset="${RESTIC_CHECK_SUBSET:-5%}"
REMOTE
        log "OK: pi-ssd"
      else
        log "SKIP pi — repo erisilemiyor"
      fi
    else
      log "SKIP pi — PI_STATIC_IP yok"
    fi
    run_check "mac-offsite" "$LOCAL_REPO"
    ;;
  *)
    die "usage: restore-check.sh [pi|local|both]"
    ;;
esac

log "Tamamlandi"
