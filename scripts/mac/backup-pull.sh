#!/usr/bin/env bash
# Mac: Pi Restic repo + config yedegini cek (offsite 3-2-1 icin)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-batu}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
LOCAL_DEST="${MAC_BACKUP_DEST:-$HOME/Backups/pi-gateway}"
RESTIC_REMOTE="${RESTIC_REPOSITORY:-/mnt/ssd/pi-gateway-data/backups/restic}"

[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli"

log() { echo "[backup-pull] $*"; }

mkdir -p "$LOCAL_DEST/restic" "$LOCAL_DEST/config-snapshots"

log "Restic repo: $PI_USER@$PI_HOST:$RESTIC_REMOTE -> $LOCAL_DEST/restic"
rsync -avz --delete \
  "$PI_USER@$PI_HOST:$RESTIC_REMOTE/" \
  "$LOCAL_DEST/restic/"

log "Config snapshot (secrets haric)"
STAMP="$(date +%Y%m%d-%H%M%S)"
rsync -avz \
  --exclude '.env' \
  --exclude 'data/**' \
  --exclude 'homepage/logs/**' \
  --exclude 'crowdsec/bouncer/local_api_credentials.yaml' \
  "$PI_USER@$PI_HOST:$REMOTE_DIR/config/" \
  "$LOCAL_DEST/config-snapshots/$STAMP/" || log "WARN: config snapshot kismi basarisiz (restic OK)"

log "Tamamlandi: $LOCAL_DEST"
