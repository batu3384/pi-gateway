#!/usr/bin/env bash
# .env sifrelerini tum servis GUI'lerine uygular
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/unified-login.sh
source "$SCRIPT_DIR/../lib/unified-login.sh"
apply_unified_login

log() { echo "[sync-passwords] $*"; }

run() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || log "WARN: $name basarisiz"
}

[[ -f "$REMOTE_DIR/.env" ]] || { log "HATA: .env yok"; exit 1; }

run "Dozzle" "$SCRIPT_DIR/setup-dozzle.sh"
run "Uptime Kuma" "$SCRIPT_DIR/setup-uptime-kuma.sh"
run "Forgejo" "$SCRIPT_DIR/setup-forgejo.sh"
run "Syncthing" "$SCRIPT_DIR/setup-syncthing-auth.sh"

log "Tamamlandi"
