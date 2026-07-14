#!/usr/bin/env bash
# Host sertlestirme: gereksiz servisler, UFW guncelleme
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[harden-host] $*"; }

disable_rpcbind() {
  if systemctl is-active --quiet rpcbind 2>/dev/null || systemctl is-enabled --quiet rpcbind 2>/dev/null; then
    log "rpcbind kapatiliyor (NFS kullanilmiyor)"
    sudo systemctl disable --now rpcbind rpcbind.socket 2>/dev/null || \
      sudo systemctl disable --now rpcbind 2>/dev/null || true
  else
    log "rpcbind zaten kapali"
  fi
}

fix_adguard_config_perms() {
  local cfg="$REMOTE_DIR/config/adguard/AdGuardHome.yaml"
  [[ -f "$cfg" ]] || return 0
  if [[ ! -r "$cfg" ]]; then
    log "AdGuard config izinleri duzeltiliyor"
    sudo chown "${USER}:${USER}" "$cfg"
    chmod 640 "$cfg"
  fi
}

main() {
  disable_rpcbind
  fix_adguard_config_perms
  # UFW post-deploy sonunda uygulanir (caddy-only kurallari ezilmesin)
  log "Tamamlandi"
}

main "$@"
