#!/usr/bin/env bash
# Deploy oncesi: Pi'de data symlink + Mac repo'da data/ klasoru kontrolu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"

[[ -n "$PI_HOST" ]] || die "PI_HOST required"

if [[ -d "$PROJECT_DIR/data" && ! -L "$PROJECT_DIR/data" ]]; then
  if find "$PROJECT_DIR/data" -type f -print -quit 2>/dev/null | grep -q .; then
    die "Mac repo'da data/ icinde dosya var — tasiyin; rsync Pi verisini bozabilir"
  fi
  log "WARN: bos data/ klasoru siliniyor (Mac repo; runtime veri Pi SSD'de)"
  rm -rf "$PROJECT_DIR/data"
fi

DEPLOY_HOST="${PI_STATIC_IP:-$PI_HOST}"
log "Pre-deploy: data symlink kontrolu ($PI_USER@$DEPLOY_HOST)"

ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../lib/ensure-data-symlink.sh" verify 2>/dev/null && {
  log "Pre-deploy: data symlink OK"
  exit 0
}

log "Pre-deploy: symlink bozuk — onarim deneniyor"
ssh "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../pi/ensure-data-symlink.sh" repair

ssh "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../lib/ensure-data-symlink.sh" verify

log "Pre-deploy: symlink onarildi"
