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

if [[ -x "$SCRIPT_DIR/dns-host-fallback.sh" ]]; then
  bash "$SCRIPT_DIR/dns-host-fallback.sh" start || true
fi

if [[ -d "$REMOTE_DIR/compose" ]]; then
  (cd "$REMOTE_DIR/compose" && timeout 20 docker compose --env-file ../.env stop) 2>/dev/null \
    || log "WARN: compose stop"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  systemctl stop docker docker.socket 2>/dev/null || systemctl stop docker
else
  sudo systemctl stop docker docker.socket 2>/dev/null || sudo systemctl stop docker
fi
_kv_exists=0
if [[ "$(id -u)" -eq 0 ]]; then
  [[ -f "$kv" ]] && _kv_exists=1
else
  sudo test -f "$kv" 2>/dev/null && _kv_exists=1
fi
if [[ "$_kv_exists" -eq 1 ]]; then
  bak="${kv}.bak.$(date +%s)"
  if [[ "$(id -u)" -eq 0 ]]; then
    mv "$kv" "$bak" 2>/dev/null || rm -f "$kv"
    find "$(dirname "$kv")" -maxdepth 1 -name 'local-kv.db.bak.*' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | awk 'NR>2 {print $2}' | xargs -r rm -f 2>/dev/null || true
  else
    sudo mv "$kv" "$bak" 2>/dev/null || sudo rm -f "$kv"
    sudo find "$(dirname "$kv")" -maxdepth 1 -name 'local-kv.db.bak.*' -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | awk 'NR>2 {print $2}' | sudo xargs -r rm -f 2>/dev/null || true
  fi
  log "local-kv yedeklendi: $bak"
fi
if [[ "$(id -u)" -eq 0 ]]; then
  systemctl start docker
else
  sudo systemctl start docker
fi
for _ in 1 2 3 4 5 6 7 8; do
  docker info >/dev/null 2>&1 && break
  sleep 2
done
docker network prune -f >/dev/null 2>&1 || true
if docker_sandbox_ok; then
  log "OK"
  exit 0
fi
log "HATA: docker sandbox hala fail — SSD soft-reset gerekebilir"
exit 1
