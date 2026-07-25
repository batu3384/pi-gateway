#!/usr/bin/env bash
# Pre-deploy: Mac data/ safety + optional Pi symlink check
# Fresh installs often have no SSD mount yet — bootstrap creates it. Soft-fail then.
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
    die "Mac repo has files under data/ — move them; rsync can clobber Pi data"
  fi
  log "WARN: removing empty Mac data/ directory (runtime data lives on Pi SSD)"
  rm -rf "$PROJECT_DIR/data"
fi

DEPLOY_HOST="${PI_STATIC_IP:-$PI_HOST}"
log "Pre-deploy: data symlink check ($PI_USER@$DEPLOY_HOST)"

if ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../lib/ensure-data-symlink.sh" verify 2>/dev/null; then
  log "Pre-deploy: data symlink OK"
  exit 0
fi

log "Pre-deploy: symlink missing/broken — attempting repair"
if ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../pi/ensure-data-symlink.sh" repair 2>/dev/null \
  && ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../lib/ensure-data-symlink.sh" verify 2>/dev/null; then
  log "Pre-deploy: symlink repaired"
  exit 0
fi

# Fresh hybrid install: SSD not formatted/mounted until bootstrap — continue
log "WARN: pre-deploy symlink not ready yet — bootstrap will prepare SSD/data"
exit 0
