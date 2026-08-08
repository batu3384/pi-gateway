#!/usr/bin/env bash
# Dozzle users.yml olusturur (DOZZLE_AUTH_PROVIDER=simple)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"

DOZZLE_ADMIN_USER="${DOZZLE_ADMIN_USER:-admin}"
DOZZLE_ADMIN_PASSWORD="${DOZZLE_ADMIN_PASSWORD:-}"
DATA_DIR="${REMOTE_DIR}/data/dozzle"

log() { echo "[dozzle-setup] $*"; }

[[ -n "$DOZZLE_ADMIN_PASSWORD" ]] || { log "HATA: DOZZLE_ADMIN_PASSWORD bos — fail-closed"; exit 1; }
case "$DOZZLE_ADMIN_PASSWORD" in
  CHANGE_ME*|Degistir*|changeme*|password) log "HATA: DOZZLE_ADMIN_PASSWORD placeholder"; exit 1 ;;
esac

mkdir -p "$DATA_DIR"

log "users.yml olusturuluyor: ${DOZZLE_ADMIN_USER}"
DOZZLE_IMAGE="${DOZZLE_IMAGE:-amir20/dozzle:v8.14.12}"
docker run --rm "$DOZZLE_IMAGE" generate "${DOZZLE_ADMIN_USER}" \
  --password "${DOZZLE_ADMIN_PASSWORD}" \
  --name "${DOZZLE_ADMIN_USER}" > "${DATA_DIR}/users.yml"

chmod 600 "${DATA_DIR}/users.yml"
log "Tamamlandi — http://$(hostname -I 2>/dev/null | awk '{print $1}'):${DOZZLE_PORT:-9999}"
