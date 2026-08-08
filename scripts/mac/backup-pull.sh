#!/usr/bin/env bash
# Mac: Pi Restic repo + config yedegini cek (offsite 3-2-1 icin)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_STATIC_IP:-${PI_HOST:-}}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
LOCAL_DEST="${MAC_BACKUP_DEST:-$HOME/Backups/pi-gateway}"
RESTIC_REMOTE="${RESTIC_REPOSITORY:-${REMOTE_DIR}/data/backups/restic}"
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic:0.17.3}"
RESTIC_REINIT_MARKER="${RESTIC_REINIT_MARKER:-/var/lib/pi-gateway/restic-reinit}"

[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli"

log() { echo "[backup-pull] $*"; }

[[ "${ENABLE_RESTIC:-true}" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "RESTIC_PASSWORD .env icinde bos"

mkdir -p "$LOCAL_DEST/restic" "$LOCAL_DEST/config-snapshots"

count_snapshots() {
  local repo="$1"
  [[ -d "$repo" ]] || { echo 0; return 0; }
  timeout 120 docker run --rm --network none \
    -e RESTIC_PASSWORD \
    -v "${repo}:/repo:ro" \
    "$RESTIC_IMAGE" -r "local:/repo" snapshots --json 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)' \
    2>/dev/null || echo 0
}

# Reinit / shrink gate: --delete eski offsite'i silmesin
if ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_USER@$PI_HOST" \
  "test -f '$RESTIC_REINIT_MARKER'" 2>/dev/null; then
  die "Pi restic-reinit marker var ($RESTIC_REINIT_MARKER) — --delete yasak. Corrupt repo inceleyin; marker'i bilinçli silin."
fi

remote_tmp="$(mktemp -d)"
trap 'rm -rf "$remote_tmp"' EXIT
log "On kontrol: snapshot sayisi"
if ! rsync -az --timeout=60 \
  "$PI_USER@$PI_HOST:$RESTIC_REMOTE/" \
  "$remote_tmp/restic/" 2>/dev/null; then
  die "Pi restic repo cekilemedi: $RESTIC_REMOTE"
fi
remote_n="$(count_snapshots "$remote_tmp/restic")"
local_n="$(count_snapshots "$LOCAL_DEST/restic")"
log "snapshot remote=$remote_n local=$local_n"
if [[ "$local_n" -gt 0 && "$remote_n" -lt "$local_n" ]]; then
  die "REFUSE --delete: remote snapshot ($remote_n) < local ($local_n) — olasi reinit/shrink"
fi
if [[ "$remote_n" -eq 0 ]]; then
  die "Pi restic repo bos veya okunamadi — offsite ezilmez"
fi

log "Restic repo: $PI_USER@$PI_HOST:$RESTIC_REMOTE -> $LOCAL_DEST/restic"
if ! rsync -avz --delete --ignore-errors \
  "$PI_USER@$PI_HOST:$RESTIC_REMOTE/" \
  "$LOCAL_DEST/restic/"; then
  die "restic rsync basarisiz — .last-success yazilmiyor"
fi

log "Config snapshot (secrets haric)"
STAMP="$(date +%Y%m%d-%H%M%S)"
rsync -avz \
  --exclude '.env' \
  --exclude 'data/**' \
  --exclude 'homepage/logs/**' \
  --exclude 'crowdsec/bouncer/local_api_credentials.yaml' \
  "$PI_USER@$PI_HOST:$REMOTE_DIR/config/" \
  "$LOCAL_DEST/config-snapshots/$STAMP/" || log "WARN: config snapshot kismi basarisiz (restic OK)"

date -Iseconds >"$LOCAL_DEST/.last-success"
log "Stamp: $LOCAL_DEST/.last-success"

if ssh -o ConnectTimeout=10 -o BatchMode=yes "$PI_USER@$PI_HOST" \
  "sudo mkdir -p /var/lib/pi-gateway && date -Iseconds | sudo tee /var/lib/pi-gateway/last-offsite-backup >/dev/null && sudo chmod 644 /var/lib/pi-gateway/last-offsite-backup" \
  2>/dev/null; then
  log "Pi marker: /var/lib/pi-gateway/last-offsite-backup"
else
  log "WARN: Pi offsite marker yazilamadi (SSH/sudo) — Mac stamp yine de gecerli"
fi

log "Tamamlandi: $LOCAL_DEST"
