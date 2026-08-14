#!/usr/bin/env bash
# NetAlertX: bozuk DB sifirla + yeniden kur
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
DATA_DIR="${REMOTE_DIR}/data/netalertx"
DB_DIR="${DATA_DIR}/db"
BACKUP_DIR="${DATA_DIR}/backups"
log() { echo "[repair-netalertx] $*"; }
[[ "${ENABLE_NETALERTX:-true}" == "true" ]] || { log "NetAlertX kapali"; exit 0; }
docker ps --format '{{.Names}}' | grep -q '^netalertx$' || { log "HATA: netalertx container yok"; exit 1; }
mkdir -p "${BACKUP_DIR}"
stamp="$(date +%Y%m%d-%H%M%S)"
if [[ -d "$DB_DIR" ]] && ls "$DB_DIR"/* >/dev/null 2>&1; then
  tar -czf "${BACKUP_DIR}/db-${stamp}.tar.gz" -C "$DATA_DIR" db 2>/dev/null || true
  log "Yedek: ${BACKUP_DIR}/db-${stamp}.tar.gz"
fi
log "Container durduruluyor..."
docker stop netalertx >/dev/null 2>&1 || true
log "DB temizleniyor..."
sudo mkdir -p "${BACKUP_DIR}"
if [[ -d "$DB_DIR" ]] && ls "$DB_DIR"/* >/dev/null 2>&1; then
  sudo tar -czf "${BACKUP_DIR}/db-${stamp}.tar.gz" -C "$DATA_DIR" db 2>/dev/null || true
  log "Yedek: ${BACKUP_DIR}/db-${stamp}.tar.gz"
fi
sudo rm -rf "${DB_DIR:?}"/*
sudo rm -f "${DATA_DIR}/config/app.conf" "${DATA_DIR}/config/app_conf_override.json" "${DATA_DIR}/.pi-gateway-configured"
sudo mkdir -p "$DB_DIR" "${DATA_DIR}/config"
sudo chown -R 20211:20211 "$DATA_DIR"
log "Container baslatiliyor..."
docker start netalertx >/dev/null 2>&1 || true
REMOTE_DIR="$REMOTE_DIR" bash "$SCRIPT_DIR/setup-netalertx.sh"
for _ in $(seq 1 24); do
  if curl -fsS -L "http://127.0.0.1:${NETALERTX_PORT:-20211}/" >/dev/null 2>&1; then
    log "HTTP OK"
    exit 0
  fi
  sleep 5
done
log "HATA: NetAlertX hala yanit vermiyor — docker logs netalertx"
exit 1
