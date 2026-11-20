#!/usr/bin/env bash
# Docker OpenBot kaldır (veri SSD'de yedeklenir).
set -euo pipefail
OPENBOT_DOCKER_DIR="${OPENBOT_DOCKER_DIR:-/mnt/ssd/openbot}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/ssd/pi-gateway-data/backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"

log() { echo "[openbot-docker-remove] $*"; }

[[ -d "$OPENBOT_DOCKER_DIR" ]] || { log "Docker dizini yok — atlanıyor"; exit 0; }

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx openbot; then
  log "Konteyner durduruluyor"
  (cd "$OPENBOT_DOCKER_DIR" && docker compose stop openbot && docker compose rm -f openbot) \
    || docker rm -f openbot 2>/dev/null || true
fi

mkdir -p "$BACKUP_DIR"
archive="${BACKUP_DIR}/openbot-docker-config-${STAMP}.tar.gz"
recent="$(ls -t "${BACKUP_DIR}"/openbot-docker-config-*.tar.gz 2>/dev/null | head -1 || true)"
if [[ -n "$recent" && "$(( $(date +%s) - $(stat -c %Y "$recent" 2>/dev/null || echo 0) ))" -lt 7200 ]]; then
  log "Yedek atlandı (son 2 saat): $recent"
else
  log "Yedek: $archive"
  tar -C "${OPENBOT_DOCKER_DIR}/data" -czf "$archive" \
    --exclude='core.*' \
    .config/OpenBot/openbot.db \
    .config/OpenBot/automation \
    OpenBot \
    pi-gateway-fx-latest.txt 2>/dev/null \
    || log "WARN: yedek kısmi/başarısız — $archive"
fi

if [[ "${OPENBOT_DOCKER_PURGE:-false}" == "true" ]]; then
  log "PURGE: ${OPENBOT_DOCKER_DIR} siliniyor (core dump'lar dahil)"
  rm -rf "${OPENBOT_DOCKER_DIR}"
else
  find "${OPENBOT_DOCKER_DIR}/data" -maxdepth 1 -name 'core.*' -type f -delete 2>/dev/null || true
  log "compose.yaml ve data dizini duruyor; tam silme için OPENBOT_DOCKER_PURGE=true"
fi

log "Tamam — native kuruluma hazır"