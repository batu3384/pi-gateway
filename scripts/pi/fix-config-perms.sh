#!/usr/bin/env bash
# Render edilen config dosyalarinin sahipligini duzeltir (AdGuard docker root yapabiliyor)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

log() { echo "[fix-config-perms] $*"; }

fix_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ ! -O "$f" ]] || [[ ! -G "$f" ]]; then
    sudo chown "${USER}:${USER}" "$f"
    log "chown: $f"
  fi
  chmod 640 "$f" 2>/dev/null || true
}

fix_file "${REMOTE_DIR}/config/adguard/AdGuardHome.yaml"
fix_file "${REMOTE_DIR}/config/caddy/Caddyfile"

if [[ -f "${REMOTE_DIR}/.env" ]]; then
  chmod 600 "${REMOTE_DIR}/.env" 2>/dev/null || sudo chmod 600 "${REMOTE_DIR}/.env"
fi

log "Tamamlandi"
