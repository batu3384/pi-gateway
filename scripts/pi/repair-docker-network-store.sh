#!/usr/bin/env bash
# SSD I/O sonrasi docker libnetwork local-kv.db onarimi.
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/stack-health.sh
source "$SCRIPT_DIR/../lib/stack-health.sh"
log() { echo "[repair-docker-net] $*"; }

if docker_sandbox_ok; then
  log "docker sandbox OK"
  exit 0
fi

root="$(docker_data_root 2>/dev/null || echo /mnt/ssd/docker)"
kv="${root}/network/files/local-kv.db"
log "docker sandbox fail — local-kv repair ($kv)"

if [[ -d "$REMOTE_DIR/compose" ]]; then
  (cd "$REMOTE_DIR/compose" && docker compose --env-file ../.env stop) 2>/dev/null \
    || log "WARN: compose stop"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  systemctl stop docker
else
  sudo systemctl stop docker
fi
if [[ -f "$kv" ]]; then
  bak="${kv}.bak.$(date +%s)"
  if [[ "$(id -u)" -eq 0 ]]; then
    mv "$kv" "$bak" 2>/dev/null || rm -f "$kv"
  else
    sudo mv "$kv" "$bak" 2>/dev/null || sudo rm -f "$kv"
  fi
  log "local-kv yedeklendi: $bak"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  systemctl start docker
else
  sudo systemctl start docker
fi
sleep 4
docker network prune -f >/dev/null 2>&1 || true
if docker_sandbox_ok; then
  log "OK"
  exit 0
fi
log "HATA: docker sandbox hala fail — SSD soft-reset gerekebilir"
exit 1
