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
fix_file "${REMOTE_DIR}/config/homepage/services.yaml"

# Homepage log dizini rsync delete hatasini onler
if [[ -d "${REMOTE_DIR}/config/homepage/logs" ]]; then
  sudo chown -R "${USER}:${USER}" "${REMOTE_DIR}/config/homepage/logs" 2>/dev/null || true
fi

log "Tamamlandi"
