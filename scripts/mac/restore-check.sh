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
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
CHECK_SUBSET="${RESTIC_CHECK_SUBSET:-5%}"
RESTIC_TIMEOUT_SEC="${RESTIC_TIMEOUT_SEC:-7200}"
TARGET="${1:-both}"
log() { echo "[restore-check] $*"; }
die() { echo "[restore-check] HATA: $*" >&2; exit 1; }
[[ "${ENABLE_RESTIC:-true}" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "RESTIC_PASSWORD .env icinde bos"
run_check() {
  local label="$1" repo_path="$2"
  [[ -d "$repo_path" ]] || die "$label — repo yok: $repo_path"
  log "check: $label ($repo_path, subset=$CHECK_SUBSET)"
  timeout "$RESTIC_TIMEOUT_SEC" docker run --rm --network none \
    -e RESTIC_PASSWORD \
    -v "${repo_path}:/repo:ro" \
    "$RESTIC_IMAGE" -r "local:/repo" check --read-data-subset="$CHECK_SUBSET"
  log "OK: $label"
}
case "$TARGET" in
  pi)
    [[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli (target=pi)"
    RESTIC_REMOTE="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
    [[ "$RESTIC_REMOTE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "RESTIC_REPOSITORY gecersiz"
    ssh -o ConnectTimeout=15 "$PI_USER@$PI_HOST" \
      "test -d '$RESTIC_REMOTE'" || die "Pi repo yok: $RESTIC_REMOTE"
    ssh -o ConnectTimeout=15 "$PI_USER@$PI_HOST" \
      "REMOTE_DIR='$REMOTE_DIR' RESTIC_REPOSITORY='$RESTIC_REMOTE' RESTIC_CHECK_SUBSET='$CHECK_SUBSET' RESTIC_TIMEOUT_SEC='$RESTIC_TIMEOUT_SEC' RESTIC_IMAGE='$RESTIC_IMAGE' bash -s" <<'REMOTE'
set -euo pipefail
source "$REMOTE_DIR/scripts/lib/env-file.sh"
read_remote_dotenv || { echo "[restore-check] HATA: .env dotenv parser hatasi" >&2; exit 1; }
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
[[ -d "$RESTIC_REPOSITORY" ]] || { echo "[restore-check] HATA: Pi repo yok"; exit 1; }
timeout "${RESTIC_TIMEOUT_SEC:-7200}" docker run --rm --network none \
  -e RESTIC_PASSWORD \
  -v "${RESTIC_REPOSITORY}:/repo:ro" \
  "$RESTIC_IMAGE" -r "local:/repo" check --read-data-subset="${RESTIC_CHECK_SUBSET:-5%}"
REMOTE
    ;;
  local)
    run_check "mac-offsite" "$LOCAL_REPO"
    ;;
  both)
    if [[ -z "$PI_HOST" ]]; then
      die "PI_STATIC_IP gerekli (target=both)"
    fi
    RESTIC_REMOTE="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
    [[ "$RESTIC_REMOTE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "RESTIC_REPOSITORY gecersiz"
    ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_USER@$PI_HOST" "test -d '$RESTIC_REMOTE'" \
      || die "Pi repo erisilemiyor: $RESTIC_REMOTE"
    ssh -o ConnectTimeout=15 "$PI_USER@$PI_HOST" \
      "REMOTE_DIR='$REMOTE_DIR' RESTIC_REPOSITORY='$RESTIC_REMOTE' RESTIC_CHECK_SUBSET='$CHECK_SUBSET' RESTIC_TIMEOUT_SEC='$RESTIC_TIMEOUT_SEC' RESTIC_IMAGE='$RESTIC_IMAGE' bash -s" <<'REMOTE'
set -euo pipefail
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY missing}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
[[ -d "$RESTIC_REPOSITORY" ]] || { echo "[restore-check] HATA: Pi repo yok"; exit 1; }
timeout "${RESTIC_TIMEOUT_SEC:-7200}" docker run --rm --network none \
  -e RESTIC_PASSWORD \
  -v "${RESTIC_REPOSITORY}:/repo:ro" \
  "$RESTIC_IMAGE" -r "local:/repo" check --read-data-subset="${RESTIC_CHECK_SUBSET:-5%}"
REMOTE
    log "OK: pi-ssd"
    run_check "mac-offsite" "$LOCAL_REPO"
    ;;
  *)
    die "usage: restore-check.sh [pi|local|both]"
    ;;
esac
log "Tamamlandi"
