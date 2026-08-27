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
RESTIC_IMAGE="${RESTIC_IMAGE:-restic/restic@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a}"
RESTIC_REINIT_MARKER="${RESTIC_REINIT_MARKER:-/var/lib/pi-gateway/restic-reinit}"

[[ -n "$PI_HOST" ]] || die "PI_STATIC_IP gerekli"

log() { echo "[backup-pull] $*"; }

[[ "${ENABLE_RESTIC:-true}" == "true" ]] || { log "atlandi (ENABLE_RESTIC=false)"; exit 0; }
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "RESTIC_PASSWORD .env icinde bos"

mkdir -p "$LOCAL_DEST/restic" "$LOCAL_DEST/config-snapshots"

count_snapshots() {
  local repo="$1"
  [[ -d "$repo" ]] || { echo 0; return 0; }
  local out
  if command -v restic >/dev/null 2>&1; then
    out="$(timeout 120 env RESTIC_PASSWORD="$RESTIC_PASSWORD" \
      restic -r "$repo" snapshots --json 2>/dev/null)" || { echo 0; return 0; }
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    out="$(timeout 120 docker run --rm --network none \
      -e RESTIC_PASSWORD \
      -v "${repo}:/repo:ro" \
      "$RESTIC_IMAGE" -r "local:/repo" snapshots --json 2>/dev/null)" || { echo 0; return 0; }
  else
    echo 0
    return 0
  fi
  python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)' \
    <<<"$out" 2>/dev/null || echo 0
}

# Reinit / shrink gate: --delete eski offsite'i silmesin
if ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI_USER@$PI_HOST" \
  "test -f '$RESTIC_REINIT_MARKER'" 2>/dev/null; then
  die "Pi restic-reinit marker var ($RESTIC_REINIT_MARKER) — --delete yasak. Corrupt repo inceleyin; marker'i bilinçli silin."
fi

remote_tmp="$(mktemp -d)"
STAMP="$(date +%Y%m%d-%H%M%S)"
stage_root="$LOCAL_DEST/.restic-stage.$$"
stage_restic="$stage_root/restic"
stage_config="$LOCAL_DEST/config-snapshots/.stage-$STAMP"
trap 'rm -rf "$remote_tmp" "$stage_root" "$stage_config"' EXIT
mkdir -p "$stage_restic" "$stage_config"
log "On kontrol: snapshot sayisi"
if ! rsync -az --timeout=300 \
  "$PI_USER@$PI_HOST:$RESTIC_REMOTE/" \
  "$remote_tmp/restic/"; then
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
if ! rsync -a "$remote_tmp/restic/" "$stage_restic/"; then
  die "restic rsync basarisiz — .last-success yazilmiyor"
fi
previous_restic="$LOCAL_DEST/.restic-previous.$$"
if [[ -d "$LOCAL_DEST/restic" ]]; then
  mv "$LOCAL_DEST/restic" "$previous_restic" \
    || die "mevcut offsite repo staging gecisi basarisiz"
fi
if ! mv "$stage_restic" "$LOCAL_DEST/restic"; then
  [[ -d "$previous_restic" ]] && mv "$previous_restic" "$LOCAL_DEST/restic" || true
  die "offsite repo atomic gecisi basarisiz"
fi
rm -rf "$previous_restic"

log "Config snapshot (secrets haric)"
if ! rsync -avz \
  --exclude '.env' \
  --exclude 'data/**' \
  --exclude 'homepage/logs/**' \
  --exclude 'crowdsec/bouncer/local_api_credentials.yaml' \
  --exclude 'adguard/AdGuardHome.yaml' \
  "$PI_USER@$PI_HOST:$REMOTE_DIR/config/" \
  "$stage_config/"; then
  die "config snapshot basarisiz — .last-success yazilmiyor"
fi
mv "$stage_config" "$LOCAL_DEST/config-snapshots/$STAMP" \
  || die "config snapshot atomic gecisi basarisiz"

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
