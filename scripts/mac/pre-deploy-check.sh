#!/usr/bin/env bash
# Pre-deploy: Mac data/ safety + Pi symlink check
# Fresh install (no SSD yet): soft-continue — bootstrap formats/mounts SSD.
# Existing install with broken symlink: hard-fail after repair attempt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_HOST="${PI_HOST:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/$PI_USER/pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
PI_DEPLOY_HOST="${PI_DEPLOY_HOST:-}"

[[ -n "${PI_DEPLOY_HOST:-$PI_HOST}" ]] || die "PI_HOST or PI_DEPLOY_HOST required"

if [[ -d "$PROJECT_DIR/data" && ! -L "$PROJECT_DIR/data" ]]; then
  if find "$PROJECT_DIR/data" -type f -print -quit 2>/dev/null | grep -q .; then
    die "Mac repo has files under data/ — move them; rsync can clobber Pi data"
  fi
  log "WARN: removing empty Mac data/ directory (runtime data lives on Pi SSD)"
  rm -rf "$PROJECT_DIR/data"
fi

DEPLOY_HOST="${PI_DEPLOY_HOST:-${PI_STATIC_IP:-$PI_HOST}}"
log "Pre-deploy: data symlink check ($PI_USER@$DEPLOY_HOST)"

# Classify Pi state (fresh vs broken) before soft-failing
PI_STATE="$(
  ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
    "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" <<'REMOTE' 2>/dev/null || echo unreachable
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-$HOME/pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
DATA_ROOT="/mnt/ssd/pi-gateway-data"

if [[ ! -d "$REMOTE_DIR" ]]; then
  echo fresh_no_repo
  exit 0
fi

needs_symlink=false
[[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]] && needs_symlink=true

if [[ "$needs_symlink" != "true" ]]; then
  if [[ -d "${REMOTE_DIR}/data" && ! -L "${REMOTE_DIR}/data" ]]; then
    echo ok_local
  else
    echo fresh_no_data
  fi
  exit 0
fi

if ! mountpoint -q /mnt/ssd 2>/dev/null; then
  echo fresh_no_ssd
  exit 0
fi

if [[ -L "${REMOTE_DIR}/data" ]] && [[ "$(readlink -f "${REMOTE_DIR}/data" 2>/dev/null || true)" == "${DATA_ROOT}" ]]; then
  echo ok
  exit 0
fi

if [[ -e "${REMOTE_DIR}/data" ]] || [[ -L "${REMOTE_DIR}/data" ]]; then
  echo broken
  exit 0
fi

echo fresh_no_data
REMOTE
)"

case "$PI_STATE" in
  ok|ok_local)
    log "Pre-deploy: data path OK ($PI_STATE)"
    exit 0
    ;;
  fresh_no_repo|fresh_no_ssd|fresh_no_data)
    log "WARN: pre-deploy fresh state ($PI_STATE) — bootstrap will prepare SSD/data"
    exit 0
    ;;
  unreachable)
    die "Pre-deploy: cannot SSH to $PI_USER@$DEPLOY_HOST"
    ;;
  broken)
    log "Pre-deploy: broken data symlink — attempting repair"
    ;;
  *)
    log "WARN: unknown Pi state '$PI_STATE' — attempting repair"
    ;;
esac

if ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../pi/ensure-data-symlink.sh" repair 2>/dev/null \
  && ssh -o ConnectTimeout=15 "$PI_USER@$DEPLOY_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' STORAGE_TYPE='$STORAGE_TYPE' bash -s" \
  < "$SCRIPT_DIR/../lib/ensure-data-symlink.sh" verify 2>/dev/null; then
  log "Pre-deploy: symlink repaired"
  exit 0
fi

die "Pre-deploy: data symlink broken and repair failed — fix /mnt/ssd or run bootstrap manually"
