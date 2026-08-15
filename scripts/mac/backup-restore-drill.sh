#!/usr/bin/env bash
# Mac: restic restore drill — latest snapshot -> temp, verify, stamp (3-2-1 confidence)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
LOCAL_DEST="${MAC_BACKUP_DEST:-$HOME/Backups/pi-gateway}"
LOCAL_REPO="${LOCAL_DEST}/restic"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
DRILL_SUBSET="${RESTIC_DRILL_SUBSET:-latest}"
DRILL_TIMEOUT_SEC="${RESTIC_DRILL_TIMEOUT_SEC:-1800}"
DRILL_MARKER_LOCAL="${LOCAL_DEST}/.last-restore-drill"
DRILL_MARKER_PI="${DRILL_MARKER_PI:-/var/lib/pi-gateway/last-backup-restore-drill}"

log() { echo "[backup-drill] $*"; }
die() { echo "[backup-drill] HATA: $*" >&2; exit 1; }

[[ "${ENABLE_RESTIC:-true}" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "RESTIC_PASSWORD .env icinde bos"
[[ -d "$LOCAL_REPO" ]] || die "offsite repo yok — once make backup-pull"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
log "restore $DRILL_SUBSET -> $tmpdir"
if ! timeout "$DRILL_TIMEOUT_SEC" docker run --rm --network none \
  -e RESTIC_PASSWORD \
  -v "${LOCAL_REPO}:/repo:ro" \
  -v "${tmpdir}:/restore" \
  "$RESTIC_IMAGE" \
  -r "local:/repo" restore "$DRILL_SUBSET" --target /restore; then
  die "restic restore basarisiz"
fi

[[ -d "$tmpdir/backup/config" ]] || die "restore: backup/config yok"
[[ -d "$tmpdir/backup/compose" ]] || die "restore: backup/compose yok"
[[ -d "$tmpdir/backup/data" ]] || die "restore: backup/data yok"
file_count="$(find "$tmpdir/backup/data" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "${file_count:-0}" -gt 0 ]] || die "restore: backup/data bos"

log "OK restore verify: config+compose+data (${file_count} dosya)"
date -Iseconds >"$DRILL_MARKER_LOCAL"
log "Mac stamp: $DRILL_MARKER_LOCAL"

if [[ -n "$PI_HOST" ]]; then
  if ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_USER@$PI_HOST" \
    "sudo mkdir -p /var/lib/pi-gateway && date -Iseconds | sudo tee '$DRILL_MARKER_PI' >/dev/null && sudo chmod 644 '$DRILL_MARKER_PI'" 2>/dev/null; then
    log "Pi stamp: $DRILL_MARKER_PI"
  else
    log "WARN: Pi drill stamp yazilamadi (SSH/sudo)"
  fi
fi

log "Tamamlandi"
