#!/usr/bin/env bash
# .env sifrelerini tum servis GUI'lerine uygular
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }

log() { echo "[sync-passwords] $*"; }

run() {
  local name="$1" script="$2"
  log ">> $name"
  REMOTE_DIR="$REMOTE_DIR" bash "$script" || log "WARN: $name basarisiz"
}

[[ -f "$REMOTE_DIR/.env" ]] || { log "HATA: .env yok"; exit 1; }
[[ -n "${AGH_ADMIN_PASSWORD:-}" ]] || { log "HATA: AGH_ADMIN_PASSWORD bos"; exit 1; }

run "Dozzle" "$SCRIPT_DIR/setup-dozzle.sh"
run "Uptime Kuma" "$SCRIPT_DIR/setup-uptime-kuma.sh"
if [[ -x "$SCRIPT_DIR/setup-netalertx.sh" ]]; then
  run "NetAlertX" "$SCRIPT_DIR/setup-netalertx.sh"
fi
# Grafana compose env = AGH; reset live admin if container up
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx grafana; then
  log ">> Grafana admin reset"
  docker exec grafana grafana cli admin reset-admin-password "${GRAFANA_ADMIN_PASSWORD}" \
    >/dev/null 2>&1 || log "WARN: Grafana reset basarisiz (container eski olabilir)"
fi

log "Tamamlandi"
