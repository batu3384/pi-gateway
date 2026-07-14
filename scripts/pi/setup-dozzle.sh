#!/usr/bin/env bash
# Dozzle users.yml olusturur (DOZZLE_AUTH_PROVIDER=simple)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

DOZZLE_ADMIN_USER="${DOZZLE_ADMIN_USER:-batu}"
DOZZLE_ADMIN_PASSWORD="${DOZZLE_ADMIN_PASSWORD:-}"
DATA_DIR="${REMOTE_DIR}/data/dozzle"

log() { echo "[dozzle-setup] $*"; }

[[ -n "$DOZZLE_ADMIN_PASSWORD" ]] || { log "DOZZLE_ADMIN_PASSWORD bos — atlandi"; exit 0; }

mkdir -p "$DATA_DIR"

log "users.yml olusturuluyor: ${DOZZLE_ADMIN_USER}"
docker run --rm amir20/dozzle:latest generate "${DOZZLE_ADMIN_USER}" \
  --password "${DOZZLE_ADMIN_PASSWORD}" \
  --name "${DOZZLE_ADMIN_USER}" > "${DATA_DIR}/users.yml"

chmod 600 "${DATA_DIR}/users.yml"
log "Tamamlandi — http://$(hostname -I 2>/dev/null | awk '{print $1}'):${DOZZLE_PORT:-9999}"
