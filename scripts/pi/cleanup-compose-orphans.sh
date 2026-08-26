#!/usr/bin/env bash
# Compose'dan çıkarılmış servislerin orphan container'larını sil.
set -euo pipefail
log() { echo "[cleanup-orphans] $*"; }

REMOVED=(forgejo syncthing)
for name in "${REMOVED[@]}"; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    docker rm -f "$name" >/dev/null
    log "silindi: $name"
  fi
done

# Eski panel poller state (Hermes sole inbox)
if [[ -d /var/lib/pi-gateway/telegram-bot-state ]]; then
  sudo rm -rf /var/lib/pi-gateway/telegram-bot-state
  log "silindi: telegram-bot-state"
fi

log "OK"
