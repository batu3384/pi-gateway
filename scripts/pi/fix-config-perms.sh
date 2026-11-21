#!/usr/bin/env bash
# Render edilen config dosyalarinin sahipligini duzeltir (AdGuard docker root yapabiliyor)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

log() { echo "[fix-config-perms] $*"; }

OWNER="${PI_USER:-}"
if [[ -z "$OWNER" || "$OWNER" == "root" ]]; then
  OWNER="$(stat -c '%U' "$REMOTE_DIR" 2>/dev/null || echo "${USER:-root}")"
fi

fix_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ -n "$OWNER" && "$OWNER" != "root" ]]; then
    local cur_u cur_g
    cur_u="$(stat -c '%U' "$f" 2>/dev/null || true)"
    cur_g="$(stat -c '%G' "$f" 2>/dev/null || true)"
    if [[ "$cur_u" != "$OWNER" || "$cur_g" != "$OWNER" ]]; then
      if [[ "$(id -u)" -eq 0 ]]; then
        chown "${OWNER}:${OWNER}" "$f"
      else
        sudo chown "${OWNER}:${OWNER}" "$f"
      fi
      log "chown: $f"
    fi
  fi
  chmod 640 "$f" 2>/dev/null || sudo chmod 640 "$f" 2>/dev/null || true
}

fix_file "${REMOTE_DIR}/config/adguard/AdGuardHome.yaml"
fix_file "${REMOTE_DIR}/config/caddy/Caddyfile"
fix_file "${REMOTE_DIR}/config/glance/glance.yml"
fix_file "${REMOTE_DIR}/config/gatus/config.yaml"
if [[ -f "${REMOTE_DIR}/config/gatus/config.yaml" ]]; then
  chmod 600 "${REMOTE_DIR}/config/gatus/config.yaml" 2>/dev/null \
    || sudo chmod 600 "${REMOTE_DIR}/config/gatus/config.yaml" 2>/dev/null || true
fi

if [[ -f "${REMOTE_DIR}/.env" ]]; then
  if [[ -n "$OWNER" && "$OWNER" != "root" ]]; then
    cur_u="$(stat -c '%U' "${REMOTE_DIR}/.env" 2>/dev/null || true)"
    [[ "$cur_u" == "$OWNER" ]] || {
      if [[ "$(id -u)" -eq 0 ]]; then chown "${OWNER}:${OWNER}" "${REMOTE_DIR}/.env"; else sudo chown "${OWNER}:${OWNER}" "${REMOTE_DIR}/.env"; fi
    }
  fi
  chmod 600 "${REMOTE_DIR}/.env" 2>/dev/null || sudo chmod 600 "${REMOTE_DIR}/.env"
fi

log "Tamamlandi"
